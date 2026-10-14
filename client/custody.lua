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
    ClearPedSecondaryTask(ped)
    return
  end

  SetCurrentPedWeapon(ped, GetHashKey('WEAPON_UNARMED'), true)
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
    TaskPlayAnim(ped, 'mp_arresting', 'idle', 8.0, -8.0, -1, 49, 0.0, false, false, false)
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

RegisterNetEvent('mz_police:client:custody:result', function(response)
  if type(response) ~= 'table' or response.ok == true then return end
  print(('[mz_police][custody] request denied: %s'):format(tostring(response.code or 'unknown')))
end)

CreateThread(function()
  while true do
    if custody.cuffed then
      applyCustodyState()
      DisablePlayerFiring(PlayerId(), true)
      for _, control in ipairs({ 21, 22, 23, 24, 25, 37, 44, 45, 140, 141, 142, 143, 257, 263, 264 }) do
        DisableControlAction(0, control, true)
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
