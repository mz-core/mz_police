MZPolice = MZPolice or {}

local Bridge = {}

local function dependencyError(resourceName)
  if resourceName == 'mz_core' then return 'core_unavailable' end
  if resourceName == 'mz_org' then return 'organization_unavailable' end
  if resourceName == 'mz_inventory' then return 'inventory_unavailable' end
  if resourceName == 'mz_vehicles' then return 'vehicle_unavailable' end
  if resourceName == 'mz_economy' then return 'economy_unavailable' end
  return 'dependency_unavailable'
end

local function callExport(resourceName, exportName, ...)
  if GetResourceState(resourceName) ~= 'started' then
    return nil, dependencyError(resourceName)
  end

  local proxy = exports[resourceName]
  local exportFn = proxy and proxy[exportName]
  if type(exportFn) ~= 'function' then
    return nil, 'contract_unavailable'
  end

  local args = table.pack(...)
  local result = table.pack(pcall(function()
    return exportFn(proxy, table.unpack(args, 1, args.n))
  end))

  if result[1] ~= true then
    return nil, 'contract_failed'
  end

  return table.unpack(result, 2, result.n)
end

function Bridge.resolveIdentity(source)
  source = tonumber(source)
  if not source or source <= 0 then return nil, 'invalid_source' end

  local result, callError = callExport('mz_core', 'ResolvePlayerIdentity', source)
  if type(result) ~= 'table' or result.ok ~= true then
    return nil, type(result) == 'table' and tostring(result.error or 'identity_unavailable')
      or callError or 'identity_unavailable'
  end

  local identity = {
    source = tonumber(result.source),
    accountId = tonumber(result.accountId or result.account_id),
    characterId = tonumber(result.characterId or result.character_id),
    sessionId = tonumber(result.sessionId or result.session_id),
    citizenid = tostring(result.citizenid or ''),
    active = result.active == true
  }

  if identity.source ~= source
    or not identity.accountId or identity.accountId <= 0
    or not identity.characterId or identity.characterId <= 0
    or not identity.sessionId or identity.sessionId <= 0
    or identity.citizenid == '' then
    return nil, 'identity_inconsistent'
  end

  if identity.active ~= true then return nil, 'character_not_active' end
  return identity
end

function Bridge.organizationReady()
  local readiness, callError = callExport('mz_org', 'GetOrganizationReadiness')
  if type(readiness) ~= 'table' then return false, callError or 'organization_unavailable' end
  if readiness.ready ~= true then return false, 'organization_not_ready', readiness end
  return true, nil, readiness
end

function Bridge.getPlayerOrganizations(source)
  local organizations, callError = callExport('mz_org', 'GetPlayerOrgContext', source)
  if type(organizations) ~= 'table' then return nil, callError or 'organization_unavailable' end
  return organizations
end

function Bridge.canOrganization(source, orgCode, capability)
  local allowed, callError = callExport('mz_org', 'CanOrg', source, orgCode, capability)
  if allowed == nil then return nil, callError or 'organization_unavailable' end
  return allowed == true
end

function Bridge.createDetailedLog(action, payload)
  return callExport('mz_core', 'CreateDetailedLog', 'police', action, payload)
end

function Bridge.getDeathState(source)
  local ok, state = callExport('mz_core', 'GetDeathState', source)
  if ok ~= true or type(state) ~= 'table' then
    return nil, type(state) == 'table' and tostring(state.code or 'player_state_unavailable')
      or tostring(state or 'player_state_unavailable')
  end
  return state
end

function Bridge.createInventoryGrant(actorSource, targetSource, purpose, ttlSeconds)
  local ok, value = callExport(
    'mz_inventory', 'CreatePlayerInventoryAccessGrant',
    actorSource, targetSource, purpose, ttlSeconds
  )
  if ok ~= true then return nil, tostring(value or 'inventory_grant_failed') end
  return value
end

function Bridge.getGrantedInventory(actorSource, grantToken)
  local ok, value = callExport('mz_inventory', 'GetGrantedPlayerInventorySnapshot', actorSource, grantToken)
  if ok ~= true then return nil, tostring(value or 'inventory_snapshot_failed') end
  return value
end

function Bridge.transferGrantedItem(actorSource, grantToken, instanceUid, amount, destination, operationId)
  local ok, value = callExport(
    'mz_inventory', 'TransferGrantedPlayerItem',
    actorSource, grantToken, instanceUid, amount, destination, operationId
  )
  if ok ~= true then return nil, tostring(value or 'inventory_transfer_failed') end
  return value
end

function Bridge.revokeInventoryGrant(actorSource, grantToken)
  local ok, value = callExport('mz_inventory', 'RevokePlayerInventoryAccessGrant', actorSource, grantToken)
  if ok ~= true then return false, tostring(value or 'inventory_revoke_failed') end
  return true, value
end

MZPolice.Bridge = Bridge
