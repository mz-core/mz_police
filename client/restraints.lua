MZPoliceClient = MZPoliceClient or {}

-- Adaptador client de algemas. Apenas apresentacao, animacao e conveniencia de
-- visibilidade. Toda autorizacao, item e transicao continua no servidor.

local localeName = tostring(GetConvar('ox:locale', '')):lower()
if localeName == '' or localeName == 'pt' then localeName = 'pt-br' end
if type(lib) == 'table' and type(lib.locale) == 'function' then
  lib.locale(localeName)
end

local function L(key)
  if type(locale) == 'function' then
    local value = locale(key)
    if type(value) == 'string' and value ~= key then return value end
  end
  return key
end

MZPoliceClient.L = L

local access = {
  handcuffs = 0,
  keys = 0,
  physicalEnabled = false,
  serviceUnlock = false,
  serviceCuffsWithoutItem = true,
  requireSurrendered = true,
  maximumDistance = 2.0
}
local lastRefreshAt = 0
local lastRefreshRequestAt = 0
local requestSequence = 0

local function notify(message, kind)
  local interactions = MZPoliceClient.Interactions
  if interactions and type(interactions.notify) == 'function' then
    interactions.notify(message, kind)
  end
end

local function requestId(prefix)
  requestSequence = requestSequence + 1
  return ('%s:%s:%s'):format(prefix, GetGameTimer(), requestSequence)
end

local function currentSource()
  return GetPlayerServerId(PlayerId())
end

local function targetStateBag(serverId, key)
  serverId = tonumber(serverId)
  if not serverId or serverId <= 0 then return nil end
  local ok, value = pcall(function()
    local playerIndex = GetPlayerFromServerId(serverId)
    if not playerIndex or playerIndex == -1 then return nil end
    local player = Player(playerIndex)
    if not player or not player.state then return nil end
    return player.state[key]
  end)
  if not ok then return nil end
  return value
end

local function refresh(force)
  local now = GetGameTimer()
  if not force and now - lastRefreshRequestAt < 2000 then return end
  lastRefreshRequestAt = now
  TriggerServerEvent('mz_police:server:restraints:refresh')
end

local function requestAnim(dictionary)
  if HasAnimDictLoaded(dictionary) then return true end
  RequestAnimDict(dictionary)
  local deadline = GetGameTimer() + 3000
  while not HasAnimDictLoaded(dictionary) and GetGameTimer() < deadline do Wait(0) end
  return HasAnimDictLoaded(dictionary)
end

local function playAnim(dictionary, name, duration, flags)
  if type(TaskPlayAnim) ~= 'function' then return false end
  local ped = PlayerPedId()
  if not ped or ped == 0 then return false end
  if type(IsPedInAnyVehicle) == 'function' and IsPedInAnyVehicle(ped, false) then return false end
  if not requestAnim(dictionary) then return false end
  TaskPlayAnim(ped, dictionary, name, 8.0, -8.0, duration or -1,
    flags or 49, 0.0, false, false, false)
  return true
end

local function stopOurAnim(dictionary, name)
  if type(StopAnimTask) ~= 'function' then return end
  local ped = PlayerPedId()
  if not ped or ped == 0 then return end
  pcall(StopAnimTask, ped, dictionary, name, 1.0)
end

local function policeAccessOk()
  local interactions = MZPoliceClient.Interactions
  return interactions and type(interactions.accessOk) == 'function' and interactions.accessOk() == true
end

local function canPhysical(targetSource)
  targetSource = tonumber(targetSource)
  if not targetSource or targetSource <= 0 or targetSource == currentSource() then return false end
  if access.physicalEnabled ~= true or access.handcuffs < 1 then return false end
  -- Evita duplicar a acao policial quando o policial em servico pode usar
  -- algemas de servico. Se a configuracao exigir item, a acao fisica aparece.
  if policeAccessOk() and access.serviceCuffsWithoutItem == true then return false end
  if access.requireSurrendered ~= false and targetStateBag(targetSource, 'mz:isDowned') ~= true then
    return false
  end
  return true
end

local function canKey(targetSource)
  targetSource = tonumber(targetSource)
  if not targetSource or targetSource <= 0 or targetSource == currentSource() then return false end
  if access.keys < 1 then return false end
  if targetStateBag(targetSource, 'mz:restraintOrigin') ~= 'physical' then return false end
  return targetStateBag(targetSource, 'mz:restrained') == true
end

local function sendRequest(channel, action, targetSource, expectedRevision)
  targetSource = tonumber(targetSource)
  if not targetSource or targetSource <= 0 then return false end
  TriggerServerEvent('mz_police:server:restraints:request', {
    channel = channel,
    action = action,
    targetSource = targetSource,
    expectedRevision = math.max(0, math.floor(tonumber(expectedRevision) or 0)),
    requestId = requestId(channel .. '_' .. action)
  })
  return true
end

local function applyPhysical(targetSource)
  if not canPhysical(targetSource) then
    notify(L('restraint.error.physical_cuffs_disabled'), 'error')
    return false
  end
  return sendRequest('physical', 'cuff', targetSource, 0)
end

local function applyKey(targetSource)
  if not canKey(targetSource) then
    notify(L('restraint.error.key_not_held'), 'error')
    return false
  end
  return sendRequest(
    'physical', 'uncuff', targetSource,
    targetStateBag(targetSource, 'mz:restraintRevision') or 0
  )
end

RegisterNetEvent('mz_police:client:restraints:access', function(payload)
  if type(payload) ~= 'table' then return end
  access = {
    handcuffs = math.max(0, math.floor(tonumber(payload.handcuffs) or 0)),
    keys = math.max(0, math.floor(tonumber(payload.keys) or 0)),
    physicalEnabled = payload.physicalEnabled == true,
    serviceUnlock = payload.serviceUnlock == true,
    serviceCuffsWithoutItem = payload.serviceCuffsWithoutItem ~= false,
    requireSurrendered = payload.requireSurrendered ~= false,
    maximumDistance = tonumber(payload.maximumDistance) or 2.0
  }
  lastRefreshAt = GetGameTimer()
end)

RegisterNetEvent('mz_police:client:restraints:accessRefresh', function()
  refresh(true)
end)

RegisterNetEvent('mz_police:client:restraints:result', function(payload)
  if type(payload) ~= 'table' then return end
  local action = tostring(payload.action or '')
  local response = type(payload.response) == 'table' and payload.response or {}
  local code = tostring(response.code or '')
  refresh(true)
  if response.ok == true and response.pending == true then
    notify(L('restraint.applying'), 'inform')
    return
  end
  if response.ok == true then
    if code == 'custody_updated' then
      notify(action == 'uncuff' and L('restraint.removed') or L('restraint.applied'), 'success')
    else
      notify(L('restraint.updated'), 'success')
    end
    return
  end
  local translated = L('restraint.error.' .. code)
  if type(translated) ~= 'string' or translated == 'restraint.error.' .. code then
    translated = L('restraint.failed')
  end
  local debug = type(MZPoliceConfig) == 'table' and MZPoliceConfig.Debug or nil
  if code ~= '' and type(debug) == 'table' and debug.verboseErrors == true then
    translated = ('%s [%s]'):format(translated, code)
  end
  notify(translated, 'error')
end)

RegisterNetEvent('mz_police:client:restraints:animation', function(payload)
  if type(payload) ~= 'table' then return end
  local phase = tostring(payload.phase or '')
  local duration = math.max(200, tonumber(payload.duration) or 1200)
  local me = currentSource()
  local isTarget = tonumber(payload.targetSource) == me
  local isActor = tonumber(payload.actorSource) == me
  if not isTarget and not isActor then return end

  if phase == 'apply_start' then
    MZPoliceClient.RestraintAnimationUntil = GetGameTimer() + duration
    if isTarget then
      playAnim('mp_arrest_paired', 'crook_p2_back_left', duration, 48)
    else
      playAnim('mp_arrest_paired', 'cop_p2_back_left', duration, 48)
    end
  elseif phase == 'remove_start' then
    MZPoliceClient.RestraintAnimationUntil = GetGameTimer() + duration
    if isTarget then
      playAnim('mp_arresting', 'b_uncuff', duration, 49)
    else
      playAnim('mp_arrest_paired', 'cop_p2_back_left', duration, 48)
    end
  elseif phase == 'apply_failed' or phase == 'remove_failed' then
    stopOurAnim('mp_arrest_paired', 'crook_p2_back_left')
    stopOurAnim('mp_arrest_paired', 'cop_p2_back_left')
    stopOurAnim('mp_arresting', 'b_uncuff')
  end
end)

RegisterNetEvent('mz_police:client:restraints:restored', function(state)
  refresh(true)
  if type(state) == 'table' and state.cuffed == true then
    notify(L('restraint.restored'), 'inform')
  end
end)

RegisterNetEvent('mz_inventory:client:itemReceived', function()
  refresh(true)
end)

RegisterNetEvent('mz_core:client:playerLoaded', function()
  refresh(true)
end)

CreateThread(function()
  Wait(1500)
  refresh(true)
  while true do
    Wait(10000)
    refresh(false)
  end
end)

MZPoliceClient.Restraints = {
  Refresh = refresh,
  Access = function() return access end,
  CanPhysical = canPhysical,
  CanKey = canKey,
  ApplyPhysical = applyPhysical,
  ApplyKey = applyKey,
  TargetStateBag = targetStateBag
}
