MZPolice = MZPolice or {}

local Search = {}
local sessions = {}
local rateLimits = {}
local OPEN_KEYS = { targetSource = true, requestId = true }
local SEIZE_KEYS = { searchId = true, instanceUid = true, amount = true, operationId = true, containerId = true }
local CLOSE_KEYS = { searchId = true }

local function result(ok, code, extra)
  local value = { ok = ok == true, code = tostring(code) }
  for key, item in pairs(type(extra) == 'table' and extra or {}) do value[key] = item end
  return value
end

local function closedPayload(value, keys)
  if type(value) ~= 'table' then return false end
  for key in pairs(value) do if not keys[key] then return false end end
  return true
end

local function identifier(value, minimum, maximum)
  value = tostring(value or '')
  if #value < minimum or #value > maximum or not value:match('^[%w:_-]+$') then return nil end
  return value
end

local function nowMs()
  if type(GetGameTimer) == 'function' then return tonumber(GetGameTimer()) or 0 end
  return os.time() * 1000
end

local function rateAllowed(source)
  local config = MZPoliceConfig.Search.rateLimit or {}
  local current = nowMs()
  local bucket = rateLimits[source]
  if not bucket or current - bucket.startedAt >= (tonumber(config.windowMs) or 5000) then
    rateLimits[source] = { startedAt = current, count = 1 }
    return true
  end
  if bucket.count >= (tonumber(config.maximum) or 8) then return false end
  bucket.count = bucket.count + 1
  return true
end

local function sessionKey(actor, searchId)
  return ('%s:%s:%s'):format(actor.source, actor.sessionId, searchId)
end

local function revoke(session)
  if not session then return end
  MZPolice.Bridge.revokeInventoryGrant(session.actor.source, session.grantToken)
  sessions[session.key] = nil
end

local function currentSession(actorSource, searchId)
  local actor, err = MZPolice.Bridge.resolveIdentity(actorSource)
  if not actor then return nil, err end
  local session = sessions[sessionKey(actor, searchId)]
  if not session then return nil, 'search_session_not_found' end
  if os.time() >= session.expiresAt then
    revoke(session)
    return nil, 'search_session_expired'
  end
  local targetState = MZPolice.Custody.get(session.target.source)
  if not targetState or not targetState.cuffed
    or not targetState.target or targetState.target.sessionId ~= session.target.sessionId then
    revoke(session)
    return nil, 'target_not_in_custody'
  end
  return session
end

function Search.open(actorSource, payload)
  if not closedPayload(payload, OPEN_KEYS) then return result(false, 'invalid_payload') end
  actorSource = tonumber(actorSource)
  if not actorSource or actorSource <= 0 then return result(false, 'invalid_source') end
  if not rateAllowed(actorSource) then return result(false, 'rate_limited') end
  local targetSource = tonumber(payload.targetSource)
  local searchId = identifier(payload.requestId, 8, 96)
  if not targetSource or targetSource <= 0 or targetSource == tonumber(actorSource) then
    return result(false, 'invalid_target')
  end
  if not searchId then return result(false, 'invalid_request_id') end

  local authorization = MZPolice.Policy.authorize(actorSource, 'police.search')
  if authorization.ok ~= true then return result(false, authorization.code) end
  local custody = MZPolice.Custody.get(targetSource)
  if not custody or not custody.cuffed then return result(false, 'target_not_in_custody') end
  local target, targetErr = MZPolice.Bridge.resolveIdentity(targetSource)
  if not target then return result(false, targetErr) end
  if not custody.target or custody.target.sessionId ~= target.sessionId then
    return result(false, 'target_session_changed')
  end

  local key = sessionKey(authorization.identity, searchId)
  local existing = sessions[key]
  if existing then
    if existing.target.source ~= targetSource then return result(false, 'request_id_conflict') end
    local snapshot, snapshotErr = MZPolice.Bridge.getGrantedInventory(actorSource, existing.grantToken)
    if not snapshot then return result(false, snapshotErr) end
    return result(true, 'search_opened', {
      searchId = searchId, targetSource = targetSource,
      canSeize = existing.canSeize, inventory = snapshot.inventory
    })
  end

  local canSeize = MZPolice.Bridge.canOrganization(
    actorSource, authorization.organization.code, 'police.seize'
  ) == true
  local grant, grantErr = MZPolice.Bridge.createInventoryGrant(
    actorSource, targetSource, canSeize and 'seizure' or 'search', MZPoliceConfig.Search.grantTtlSeconds
  )
  if not grant then return result(false, grantErr) end
  local snapshot, snapshotErr = MZPolice.Bridge.getGrantedInventory(actorSource, grant.grantToken)
  if not snapshot then
    MZPolice.Bridge.revokeInventoryGrant(actorSource, grant.grantToken)
    return result(false, snapshotErr)
  end

  sessions[key] = {
    key = key,
    searchId = searchId,
    actor = authorization.identity,
    target = target,
    orgCode = authorization.organization.code,
    grantToken = grant.grantToken,
    canSeize = canSeize,
    expiresAt = math.min(tonumber(grant.expiresAt) or os.time(),
      os.time() + (tonumber(MZPoliceConfig.Search.sessionRetentionSeconds) or 45))
  }
  return result(true, 'search_opened', {
    searchId = searchId, targetSource = targetSource,
    canSeize = canSeize, inventory = snapshot.inventory
  })
end

function Search.seize(actorSource, payload)
  if not closedPayload(payload, SEIZE_KEYS) then return result(false, 'invalid_payload') end
  actorSource = tonumber(actorSource)
  if not actorSource or actorSource <= 0 then return result(false, 'invalid_source') end
  if not rateAllowed(actorSource) then return result(false, 'rate_limited') end
  local searchId = identifier(payload.searchId, 8, 96)
  local instanceUid = identifier(payload.instanceUid, 1, 64)
  local operationId = identifier(payload.operationId, 8, 96)
  local containerId = identifier(payload.containerId or MZPoliceConfig.Search.defaultEvidenceContainer, 2, 48)
  local amount = tonumber(payload.amount)
  if not searchId or not instanceUid or not operationId or not containerId
    or not amount or amount <= 0 or amount % 1 ~= 0 then
    return result(false, 'invalid_payload')
  end
  local authorization = MZPolice.Policy.authorize(actorSource, 'police.seize')
  if authorization.ok ~= true then return result(false, authorization.code) end
  local session, sessionErr = currentSession(actorSource, searchId)
  if not session then return result(false, sessionErr) end
  if not session.canSeize or session.actor.sessionId ~= authorization.identity.sessionId then
    return result(false, 'search_seizure_denied')
  end
  if session.orgCode ~= authorization.organization.code then return result(false, 'search_seizure_denied') end

  local transfer, transferErr = MZPolice.Bridge.transferGrantedItem(
    actorSource, session.grantToken, instanceUid, amount,
    { type = 'police_evidence', orgCode = session.orgCode, containerId = containerId },
    operationId
  )
  if not transfer then return result(false, transferErr) end
  local snapshot, snapshotErr = MZPolice.Bridge.getGrantedInventory(actorSource, session.grantToken)
  if not snapshot then return result(false, snapshotErr) end
  return result(true, 'item_seized', {
    searchId = searchId,
    targetSource = session.target.source,
    canSeize = session.canSeize,
    operationId = operationId,
    transfer = transfer,
    inventory = snapshot.inventory
  })
end

function Search.close(actorSource, payload)
  if not closedPayload(payload, CLOSE_KEYS) then return result(false, 'invalid_payload') end
  actorSource = tonumber(actorSource)
  if not actorSource or actorSource <= 0 then return result(false, 'invalid_source') end
  if not rateAllowed(actorSource) then return result(false, 'rate_limited') end
  local searchId = identifier(payload.searchId, 8, 96)
  if not searchId then return result(false, 'invalid_request_id') end
  local actor, actorErr = MZPolice.Bridge.resolveIdentity(actorSource)
  if not actor then return result(false, actorErr) end
  local session = sessions[sessionKey(actor, searchId)]
  if not session then return result(true, 'search_closed') end
  revoke(session)
  return result(true, 'search_closed')
end

function Search.snapshot(actorSource, searchId)
  local session, err = currentSession(actorSource, searchId)
  if not session then return false, err end
  local snapshot, snapshotErr = MZPolice.Bridge.getGrantedInventory(actorSource, session.grantToken)
  if not snapshot then return false, snapshotErr end
  return true, snapshot.inventory
end

function Search.closeOwned(actorSource, searchId)
  local actor = MZPolice.Bridge.resolveIdentity(actorSource)
  if not actor then return false end
  local session = sessions[sessionKey(actor, searchId)]
  if not session then return false end
  revoke(session)
  return true
end

function Search.cleanupSource(source)
  source = tonumber(source)
  if not source then return end
  rateLimits[source] = nil
  local doomed = {}
  for _, session in pairs(sessions) do
    if session.actor.source == source or session.target.source == source then doomed[#doomed + 1] = session end
  end
  for _, session in ipairs(doomed) do revoke(session) end
end

function Search.sweep()
  local doomed = {}
  for _, session in pairs(sessions) do
    if os.time() >= session.expiresAt then doomed[#doomed + 1] = session
    else
      local custody = MZPolice.Custody.get(session.target.source)
      if not custody or not custody.cuffed or not custody.target
        or custody.target.sessionId ~= session.target.sessionId then
        doomed[#doomed + 1] = session
      end
    end
  end
  for _, session in ipairs(doomed) do revoke(session) end
end

function Search.stop()
  local doomed = {}
  for _, session in pairs(sessions) do doomed[#doomed + 1] = session end
  for _, session in ipairs(doomed) do revoke(session) end
end

MZPolice.Search = Search

-- Consulta interna do mz_inventory; nenhuma decisão de autorização vem do client.
exports('AuthorizeThirdPartyInventoryRead', function(actorSource, targetSource, mode)
  if GetInvokingResource() ~= 'mz_inventory' then return false, 'resource_not_authorized' end
  actorSource, targetSource = tonumber(actorSource), tonumber(targetSource)
  if not actorSource or not targetSource or actorSource <= 0 or targetSource <= 0
    or actorSource == targetSource then return false, 'invalid_target' end

  local custody = MZPolice.Custody.get(targetSource)
  local cuffed = custody and custody.cuffed == true
  local target, targetError = MZPolice.Bridge.resolveIdentity(targetSource)
  if not target then return false, targetError or 'target_offline' end
  local death, deathError = MZPolice.Bridge.getDeathState(targetSource)
  if not death then return false, deathError or 'target_state_unavailable' end

  if mode == 'police_search' or mode == 'police_seizure' then
    local decision = MZPolice.Policy.authorize(actorSource, 'police.search')
    if decision.ok ~= true then return false, decision.code end
    if mode == 'police_seizure' then
      local seizure = MZPolice.Policy.authorize(actorSource, 'police.seize')
      if seizure.ok ~= true then return false, seizure.code end
      if seizure.organization.code ~= decision.organization.code then return false, 'organization_changed' end
    end
    if not cuffed or not custody.target or custody.target.sessionId ~= target.sessionId then
      return false, 'target_not_in_custody'
    end
    return true, { organization = decision.organization.code, condition = 'cuffed' }
  end
  if mode == 'civil_robbery' then
    if cuffed and custody.target and custody.target.sessionId == target.sessionId then
      return true, { condition = 'cuffed' }
    end
    if death.deathState == 'downed' then return true, { condition = 'downed' } end
    return false, 'target_not_vulnerable'
  end
  return false, 'invalid_mode'
end)
