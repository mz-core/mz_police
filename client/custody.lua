local custody = { revision = 0, cuffed = false, escortSource = nil, vehicleNetId = nil, vehicleSeat = nil }
local escorting = { targetSource = nil, revision = 0 }
local nextVehicleAttempt = 0
local acknowledgedVehicleRevision = -1

local function requestAnim(dictionary)
  if HasAnimDictLoaded(dictionary) then return true end
  RequestAnimDict(dictionary)
  local deadline = GetGameTimer() + 3000
  while not HasAnimDictLoaded(dictionary) and GetGameTimer() < deadline do Wait(0) end
  return HasAnimDictLoaded(dictionary)
end

local function detach()
  local ped = PlayerPedId()
  if IsEntityAttached(ped) then DetachEntity(ped, true, false) end
end

local function applyCustodyState()
  local ped = PlayerPedId()
  SetEnableHandcuffs(ped, custody.cuffed)
  SetPedCanPlayGestureAnims(ped, not custody.cuffed)
  if not custody.cuffed then
    detach()
    if type(IsEntityPlayingAnim) == 'function' and IsEntityPlayingAnim(ped, 'mp_arresting', 'idle', 3) then
      pcall(StopAnimTask, ped, 'mp_arresting', 'idle', 1.0)
    end
    return
  end

  local settings = type(MZPoliceConfig.Restraints) == 'table' and MZPoliceConfig.Restraints or {}
  if settings.blockWeaponUse ~= false then
    SetCurrentPedWeapon(ped, GetHashKey('WEAPON_UNARMED'), true)
  end
  if custody.vehicleNetId and not IsPedInAnyVehicle(ped, false) and GetGameTimer() >= nextVehicleAttempt then
    nextVehicleAttempt = GetGameTimer() + 500
    local vehicle = NetworkGetEntityFromNetworkId(custody.vehicleNetId)
    if vehicle ~= 0 and DoesEntityExist(vehicle) then
      local distance = #(GetEntityCoords(ped) - GetEntityCoords(vehicle))
      local seat = tonumber(custody.vehicleSeat)
      if distance <= 6.0 and seat and GetPedInVehicleSeat(vehicle, seat) == 0 then
        detach()
        TaskWarpPedIntoVehicle(ped, vehicle, seat)
      end
    end
  end
  if custody.vehicleNetId and IsPedInAnyVehicle(ped, false)
    and acknowledgedVehicleRevision ~= custody.revision then
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle ~= 0 and NetworkGetNetworkIdFromEntity(vehicle) == custody.vehicleNetId then
      acknowledgedVehicleRevision = custody.revision
      TriggerServerEvent('mz_police:server:custody:vehicleAck', {
        revision = custody.revision,
        networkId = custody.vehicleNetId
      })
    end
  end
  if not IsPedInAnyVehicle(ped, false) and requestAnim('mp_arresting')
    and not IsEntityPlayingAnim(ped, 'mp_arresting', 'idle', 3) then
    local animationUntil = MZPoliceClient and tonumber(MZPoliceClient.RestraintAnimationUntil) or 0
    if GetGameTimer() >= animationUntil then
      TaskPlayAnim(ped, 'mp_arresting', 'idle', 8.0, -8.0, -1, 49, 0.0, false, false, false)
    end
  end

  if custody.escortSource then
    local player = GetPlayerFromServerId(custody.escortSource)
    local officerPed = player ~= -1 and GetPlayerPed(player) or 0
    if officerPed ~= 0 and DoesEntityExist(officerPed) and not IsEntityAttachedToEntity(ped, officerPed) then
      AttachEntityToEntity(ped, officerPed, 11816, 0.45, 0.45, 0.0, 0.0, 0.0, 0.0,
        false, false, false, false, 2, true)
    end
  else
    detach()
  end
end

RegisterNetEvent('mz_police:client:custody:sync', function(state)
  if type(state) ~= 'table' then return end
  local revision = tonumber(state.revision)
  if not revision or revision < custody.revision then return end
  local previousVehicle = custody.vehicleNetId
  custody = {
    revision = revision,
    cuffed = state.cuffed == true,
    escortSource = tonumber(state.escortSource),
    vehicleNetId = tonumber(state.vehicleNetId),
    vehicleSeat = tonumber(state.vehicleSeat)
  }
  if custody.vehicleNetId == nil then acknowledgedVehicleRevision = -1 end
  if (previousVehicle and not custody.vehicleNetId) or state.reason == 'vehicle_remove' then
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle ~= 0 and (state.reason == 'vehicle_remove'
      or NetworkGetNetworkIdFromEntity(vehicle) == previousVehicle) then
      TaskLeaveVehicle(ped, vehicle, 16)
    end
  end
  applyCustodyState()
end)

RegisterNetEvent('mz_police:client:custody:officerSync', function(state)
  if type(state) ~= 'table' then return end
  local revision = tonumber(state.revision) or 0
  if revision < escorting.revision then return end
  escorting = {
    targetSource = state.escorting == true and tonumber(state.targetSource) or nil,
    revision = revision
  }
end)

CreateThread(function()
  local nextInventoryClose = 0
  while true do
    if custody.cuffed then
      applyCustodyState()
      local settings = type(MZPoliceConfig.Restraints) == 'table' and MZPoliceConfig.Restraints or {}
      local controls = { 21, 22, 44, 45 }
      if settings.blockAttack ~= false then
        for _, control in ipairs({ 23, 24, 25, 140, 141, 142, 143, 257, 263, 264 }) do
          controls[#controls + 1] = control
        end
      end
      if settings.blockWeaponUse ~= false then
        controls[#controls + 1] = 37
        if type(DisablePlayerFiring) == 'function' then DisablePlayerFiring(PlayerId(), true) end
      end
      if settings.restrictVehicleEntry ~= false then
        controls[#controls + 1] = 75
      end
      if settings.allowWalk == false then
        for _, control in ipairs({ 30, 31, 32, 33, 34, 35 }) do
          controls[#controls + 1] = control
        end
      end
      for _, control in ipairs(controls) do
        DisableControlAction(0, control, true)
      end
      if settings.inventoryWhileCuffed ~= true and GetGameTimer() >= nextInventoryClose then
        nextInventoryClose = GetGameTimer() + 1000
        if GetResourceState('mz_inventory') == 'started' then
          pcall(function()
            if exports['mz_inventory']:IsOpen() then exports['mz_inventory']:CloseView() end
          end)
        end
      end
      Wait(0)
    else
      Wait(500)
    end
  end
end)

AddEventHandler('onResourceStop', function(resourceName)
  if resourceName ~= GetCurrentResourceName() then return end
  custody = {
    revision = custody.revision + 1, cuffed = false, escortSource = nil,
    vehicleNetId = nil, vehicleSeat = nil
  }
  acknowledgedVehicleRevision = -1
  escorting = { targetSource = nil, revision = escorting.revision + 1 }
  applyCustodyState()
end)
