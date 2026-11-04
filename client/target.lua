-- Acoes fisicas do mz_police no cidadao mirado.
-- Acoes, custodia, MDT e autorizacao continuam em client/interactions.lua e no
-- servidor do mz_police. Este arquivo somente registra/despacha no mz_target.
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

local function LLabel(key, fallback)
  local value = L(key)
  return type(value) == 'string' and value ~= key and value or fallback
end

local PLAYER_TARGET_DISTANCE = 2.5
if type(MZPoliceConfig) == 'table' and type(MZPoliceConfig.Interactions) == 'table' then
  PLAYER_TARGET_DISTANCE = tonumber(MZPoliceConfig.Interactions.targetDistance) or PLAYER_TARGET_DISTANCE
end
local registerRetries = 0
local registerGeneration = 0
local registryState, registryReason = 'missing', 'not_registered'

local actionDefinitions = {
  { action = 'cuff', key = 'target.cuff', icon = 'lock' },
  { action = 'uncuff', key = 'target.uncuff', icon = 'unlock' },
  { action = 'escort_start', key = 'target.escort_start', icon = 'person-standing' },
  { action = 'escort_stop', key = 'target.escort_stop', icon = 'circle-stop' },
  { action = 'search', key = 'target.search', icon = 'scan-search' },
  { action = 'vehicle_put', key = 'target.vehicle_put', icon = 'car' },
  { action = 'vehicle_remove', key = 'target.vehicle_remove', icon = 'car-front' },
  { action = 'identify', key = 'target.identify', icon = 'badge-check' },
  { action = 'open_mdt', key = 'target.open_mdt', icon = 'tablet-smartphone', event = 'openMdt' },
  { action = 'transfer', key = 'target.transfer', icon = 'user-round-cog' },
  { action = 'process_arrest', key = 'target.process_arrest', icon = 'building-2', event = 'processArrest' }
}

local function targetLabels()
  local labels = {}
  for _, definition in ipairs(actionDefinitions) do
    labels[#labels + 1] = L(definition.key)
  end
  labels[#labels + 1] = LLabel('target.quick_arrest', 'Prisão rápida')
  if type(MZPoliceClient.Restraints) == 'table' then
    labels[#labels + 1] = L('target.cuff_physical')
    labels[#labels + 1] = L('target.uncuff_key')
  end
  if MZPoliceConfig.Search.thirdPartyInventoryEnabled == true then
    labels[#labels + 1] = L('target.rob')
  end
  return labels
end

local function buildCivilOptions(interactions)
  local restraints = MZPoliceClient.Restraints
  local options = {}

  if MZPoliceConfig.Search.thirdPartyInventoryEnabled == true then
    options[#options + 1] = {
      label = L('target.rob'), icon = 'hand', distance = PLAYER_TARGET_DISTANCE,
      canInteract = function(entity)
        if interactions.accessOk() then return false end
        local source = interactions.targetSource({ entity = entity })
        if not source then return false end
        local playerIndex = GetPlayerFromServerId(source)
        if not playerIndex or playerIndex == -1 then return false end
        local target = Player(playerIndex)
        local state = target and target.state
        return state and (state['mz:restrained'] == true or state['mz:deathState'] == 'downed') or false
      end,
      action = function(entity)
        return interactions.perform('rob', { entity = entity })
      end
    }
  end
  if type(restraints) ~= 'table' then return options end

  if type(restraints.CanPhysical) == 'function' then
    options[#options + 1] = {
      label = L('target.cuff_physical'),
      icon = 'lock',
      distance = PLAYER_TARGET_DISTANCE,
      canInteract = function(entity)
        local source = interactions.targetSource({ entity = entity })
        return source ~= nil and restraints.CanPhysical(source) == true
      end,
      action = function(entity)
        local source = interactions.targetSource({ entity = entity })
        if not source then return false end
        return restraints.ApplyPhysical(source)
      end
    }
  end

  if type(restraints.CanKey) == 'function' then
    options[#options + 1] = {
      label = L('target.uncuff_key'),
      icon = 'unlock',
      distance = PLAYER_TARGET_DISTANCE,
      canInteract = function(entity)
        local source = interactions.targetSource({ entity = entity })
        return source ~= nil and restraints.CanKey(source) == true
      end,
      action = function(entity)
        local source = interactions.targetSource({ entity = entity })
        if not source then return false end
        return restraints.ApplyKey(source)
      end
    }
  end

  return options
end

local function buildOptions(interactions)
  local options = {}

  for _, definition in ipairs(actionDefinitions) do
    local allowed = interactions.can(definition.action)
    local eventName = definition.event or definition.action

    options[#options + 1] = {
      label = L(definition.key),
      icon = definition.icon,
      distance = PLAYER_TARGET_DISTANCE,
      canInteract = function(entity)
        if not interactions.accessOk() then return false end
        local context = { entity = entity }
        if not interactions.targetSource(context) then return false end
        return allowed(context) == true
      end,
      action = function(entity)
        return interactions.perform(eventName, { entity = entity })
      end
    }
  end

  options[#options + 1] = {
    label = LLabel('target.quick_arrest', 'Prisão rápida'),
    icon = 'gavel',
    distance = PLAYER_TARGET_DISTANCE,
    canInteract = function(entity)
      if not interactions.accessOk() then return false end
      local context = { entity = entity }
      if not interactions.targetSource(context) then return false end
      return interactions.can('quick_arrest')(context) == true
    end,
    action = function(entity)
      local source = interactions.targetSource({ entity = entity })
      if not source or type(MZPoliceClient.OpenQuickArrest) ~= 'function' then return false end
      return MZPoliceClient.OpenQuickArrest(source) == true
    end
  }

  return options
end

local function removeTargetOptions()
  if GetResourceState('mz_target') ~= 'started' then return end
  pcall(function()
    exports['mz_target']:RemoveGlobalPlayer(targetLabels())
  end)
end

local function registerTarget()
  if GetResourceState('mz_target') ~= 'started' then return end
  local interactions = MZPoliceClient and MZPoliceClient.Interactions
  if type(interactions) ~= 'table' then return end

  removeTargetOptions()

  local options = buildOptions(interactions)
  local civilOptions = buildCivilOptions(interactions)
  for _, option in ipairs(civilOptions) do options[#options + 1] = option end
  local callOk, err = pcall(function()
    return exports['mz_target']:AddGlobalPlayer({
      distance = PLAYER_TARGET_DISTANCE,
      options = options
    })
  end)

  if not callOk then
    registryState, registryReason = 'error', tostring(err or 'register_failed')
    print(('[mz_police][target] register failed: %s'):format(tostring(err)))
    if registerRetries < 5 then
      registerRetries = registerRetries + 1
      CreateThread(function()
        Wait(1000)
        registerTarget()
      end)
    end
    return false
  end

  registerRetries = 0
  registryState, registryReason = 'registered', 'global_player'
  print(('[mz_police][target] registered actions=%d surface=global_player'):format(#options))
  return true
end

local function unregisterTarget()
  registerGeneration = registerGeneration + 1
  removeTargetOptions()
  registryState, registryReason = 'missing', 'resource_stop'
end

local function requestRegister(delay)
  registerGeneration = registerGeneration + 1
  local generation = registerGeneration

  CreateThread(function()
    Wait(delay or 500)
    if generation == registerGeneration then
      registerTarget()
    end
  end)
end

MZPoliceClient.TargetIntegration = {
  Register = registerTarget,
  Unregister = unregisterTarget,
  GetStatus = function()
    return { handle = 'mz_target:global_player', state = registryState, reason = registryReason }
  end
}

requestRegister(1000)

AddEventHandler('onClientResourceStart', function(resourceName)
  if resourceName == 'mz_target' or resourceName == GetCurrentResourceName() then
    requestRegister(500)
  end
end)

AddEventHandler('mz_target:client:ready', function()
  requestRegister(0)
end)

AddEventHandler('onClientResourceStop', function(resourceName)
  if resourceName == 'mz_target' then
    registryState, registryReason = 'missing', 'provider_stopped'
    return
  end

  if resourceName == GetCurrentResourceName() then
    unregisterTarget()
  end
end)
