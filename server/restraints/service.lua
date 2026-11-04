MZPolice = MZPolice or {}

-- Orquestracao de algemas/chaves SOBRE a custodia canonica existente.
-- O owner do estado algemado continua sendo MZPolice.Custody. Este modulo
-- somente valida intencoes, controla a fase APPLYING, transaciona itens e
-- mantem a projecao/auditoria. Nenhum cliente transiciona estado diretamente.

local Restraints = {}

local ACTIONS = { cuff = true, uncuff = true }
local PAYLOAD_KEYS = {
  action = true,
  targetSource = true,
  requestId = true,
  expectedRevision = true,
  reason = true,
  command = true,
  preferredUid = true
}
local ORIGINS = { service = true, physical = true, admin = true }
local REQUEST_ID_PATTERN = '^[%w:_%-]+$'

local pending = {}
local pendingByActor = {}
local requestCache = {}
local rateLimits = {}
local lastActionAt = {}
local restitution = {}
local suspended = {}
local sequence = 0
local lastRestitutionSweep = 0

local function cfg()
  return type(MZPoliceConfig.Restraints) == 'table' and MZPoliceConfig.Restraints or {}
end

local function result(ok, code, extra)
  local value = { ok = ok == true, code = tostring(code or '') }
  for key, entry in pairs(type(extra) == 'table' and extra or {}) do value[key] = entry end
  return value
end

local function copy(value)
  if type(value) ~= 'table' then return value end
  local out = {}
  for key, entry in pairs(value) do out[key] = copy(entry) end
  return out
end

local function nowMs()
  if type(GetGameTimer) == 'function' then return tonumber(GetGameTimer()) or 0 end
  return os.time() * 1000
end

local function trim(value)
  return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function items()
  local value = cfg().items
  return {
    handcuffs = type(value) == 'table' and tostring(value.handcuffs or 'handcuffs') or 'handcuffs',
    key = type(value) == 'table' and tostring(value.key or 'handcuff_key') or 'handcuff_key'
  }
end

local function makeId(prefix)
  sequence = sequence + 1
  return ('%s:%s:%s:%s'):format(
    tostring(prefix or 'restraint'),
    tostring(os.time()),
    tostring(sequence),
    tostring(math.random(100000, 999999))
  )
end

local function normalizeReason(value)
  if value == nil then return nil end
  local text = trim(value):gsub('%s+', ' ')
  if text == '' then return nil end
  return text:sub(1, 200)
end

local function normalizePayload(payload)
  if type(payload) ~= 'table' then return nil, 'invalid_payload' end
  for key in pairs(payload) do
    if not PAYLOAD_KEYS[key] then return nil, 'invalid_payload' end
  end
  local action = tostring(payload.action or ''):lower()
  local targetSource = tonumber(payload.targetSource)
  local requestId = tostring(payload.requestId or '')
  local expectedRevision = tonumber(payload.expectedRevision)
  if not ACTIONS[action] then return nil, 'invalid_action' end
  if not targetSource or targetSource <= 0 or targetSource % 1 ~= 0 then return nil, 'invalid_target' end
  if #requestId < 8 or #requestId > 96 or not requestId:match(REQUEST_ID_PATTERN) then
    return nil, 'invalid_request_id'
  end
  if expectedRevision == nil or expectedRevision < 0 or expectedRevision % 1 ~= 0 then
    return nil, 'invalid_revision'
  end
  local command = trim(payload.command)
  if command ~= '' and (#command > 32 or not command:match('^[%w_%-]+$')) then
    return nil, 'invalid_command'
  end
  local preferredUid = trim(payload.preferredUid)
  if preferredUid ~= '' and (#preferredUid > 96 or not preferredUid:match('^[%w:_%-]+$')) then
    return nil, 'invalid_preferred_uid'
  end
  return {
    action = action,
    targetSource = targetSource,
    requestId = requestId,
    expectedRevision = expectedRevision,
    reason = normalizeReason(payload.reason),
    command = command ~= '' and command or nil,
    preferredUid = preferredUid ~= '' and preferredUid or nil
  }
end

local function rateAllowed(source)
  local settings = cfg().rateLimit or {}
  local maximum = tonumber(settings.maximum) or 6
  local windowMs = tonumber(settings.windowMs) or 5000
  local current = nowMs()
  local bucket = rateLimits[source]
  if not bucket or current - bucket.startedAt >= windowMs then
    rateLimits[source] = { startedAt = current, count = 1 }
    return true
  end
  if bucket.count >= maximum then return false end
  bucket.count = bucket.count + 1
  return true
end

local function cooldownAllowed(source)
  local current = nowMs()
  local cooldown = tonumber(cfg().cooldownMs) or 750
  local previous = lastActionAt[source] or 0
  if current - previous < cooldown then return false end
  lastActionAt[source] = current
  return true
end

local function requestKey(actor, requestId)
  return ('%s:%s:%s'):format(
    tostring(actor.source), tostring(actor.sessionId), tostring(requestId)
  )
end

local function cleanupRequestCache()
  local current = nowMs()
  for key, entry in pairs(requestCache) do
    if current >= entry.expiresAt then requestCache[key] = nil end
  end
end

local function replay(actor, request)
  cleanupRequestCache()
  local entry = requestCache[requestKey(actor, request.requestId)]
  if not entry then return nil end
  local fingerprint = ('%s:%s:%s'):format(
    request.action, request.targetSource, request.expectedRevision
  )
  if entry.fingerprint ~= fingerprint then return result(false, 'request_id_conflict') end
  return copy(entry.result)
end

local function remember(actor, request, response)
  if type(actor) ~= 'table' or type(request) ~= 'table' then return end
  requestCache[requestKey(actor, request.requestId)] = {
    fingerprint = ('%s:%s:%s'):format(
      request.action, request.targetSource, request.expectedRevision
    ),
    result = copy(response),
    expiresAt = nowMs() + (tonumber(cfg().requestRetentionMs) or 120000)
  }
end

local function coordsFor(source)
  if type(GetPlayerPed) ~= 'function' or type(GetEntityCoords) ~= 'function' then return nil end
  local ok, ped = pcall(GetPlayerPed, source)
  if not ok or not ped or ped == 0 then return nil end
  -- Nao exija DoesEntityExist aqui: em OneSync o servidor pode reportar false
  -- para um ped de jogador fora do escopo de replica, embora GetEntityCoords
  -- continue valido. O closeEnough do target usa o mesmo criterio.
  local coordsOk, coords = pcall(GetEntityCoords, ped)
  if not coordsOk or not coords then return nil end
  local x = tonumber(coords.x or coords[1])
  local y = tonumber(coords.y or coords[2])
  local z = tonumber(coords.z or coords[3])
  if not x or not y or not z then return nil end
  return { x = x, y = y, z = z }
end

local function validateProximity(leftSource, rightSource)
  if type(GetPlayerRoutingBucket) == 'function' then
    local leftBucket = tonumber(GetPlayerRoutingBucket(leftSource))
    local rightBucket = tonumber(GetPlayerRoutingBucket(rightSource))
    if leftBucket == nil or rightBucket == nil or leftBucket ~= rightBucket then
      return false, 'routing_bucket_mismatch'
    end
  end
  local left, right = coordsFor(leftSource), coordsFor(rightSource)
  if not left or not right then return false, 'position_unavailable' end
  local dx = left.x - right.x
  local dy = left.y - right.y
  local dz = left.z - right.z
  local maximum = tonumber(cfg().maximumDistance) or 2.0
  if dx * dx + dy * dy + dz * dz > maximum * maximum then return false, 'target_too_far' end
  return true
end

local function deathStateFor(source)
  if not MZPolice.Bridge or type(MZPolice.Bridge.getDeathState) ~= 'function' then
    return nil, 'player_state_unavailable'
  end
  local death, err = MZPolice.Bridge.getDeathState(source)
  if not death then return nil, err or 'player_state_unavailable' end
  local state = tostring(death.deathState or '')
  if state == '' then return nil, 'player_state_unavailable' end
  return state
end

local function playerInventory(source)
  if type(exports) ~= 'table' or not exports['mz_inventory'] then
    return nil, 'inventory_unavailable'
  end
  local callOk, ok, rows = pcall(function()
    return exports['mz_inventory']:GetPlayerInventory(source)
  end)
  if not callOk then return nil, 'inventory_contract_failed' end
  if ok ~= true then return nil, tostring(rows or 'inventory_unavailable') end
  if type(rows) ~= 'table' then return nil, 'inventory_unavailable' end
  return rows
end

local function findHandcuffs(source, preferredUid)
  local rows, err = playerInventory(source)
  if not rows then return nil, err end
  local best, bestSlot, preferred
  preferredUid = trim(preferredUid)
  for _, row in ipairs(rows) do
    if tostring(row.item or '') == items().handcuffs and (tonumber(row.amount) or 0) >= 1 then
      local uid = trim(row.instance_uid)
      local metadata = type(row.metadata) == 'table' and row.metadata or {}
      local serial = trim(metadata.serial)
      if uid == '' then return nil, 'cuff_uid_missing' end
      if serial == '' then return nil, 'cuff_serial_missing' end
      local slot = tonumber(row.slot) or math.huge
      local entry = {
        uid = uid,
        serial = serial,
        slot = slot,
        metadata = copy(metadata)
      }
      if preferredUid ~= '' and uid == preferredUid then preferred = entry end
      if not best or slot < bestSlot then
        best = entry
        bestSlot = slot
      end
    end
  end
  if preferred then return preferred end
  if not best then return nil, 'cuff_item_required' end
  return best
end

local function findMatchingKey(source, state)
  local restraint = type(state) == 'table' and state.restraint or {}
  local expectedUid = trim(restraint.itemUid)
  local expectedSerial = trim(restraint.serial)
  local expectedKeyUid = trim(restraint.keyUid)
  local expectedRestraintId = trim(restraint.id)
  if expectedUid == '' or expectedKeyUid == '' then return nil, 'no_physical_key' end

  local rows, err = playerInventory(source)
  if not rows then return nil, err end
  local sawKey = false
  for _, row in ipairs(rows) do
    if tostring(row.item or '') == items().key and (tonumber(row.amount) or 0) >= 1 then
      sawKey = true
      local metadata = type(row.metadata) == 'table' and row.metadata or {}
      local rowUid = trim(row.instance_uid)
      local linkedUid = trim(metadata.handcuff_uid)
      local linkedSerial = trim(metadata.cuff_serial)
      local linkedRestraint = trim(metadata.restraint_id)
      if rowUid == expectedKeyUid
        and linkedUid == expectedUid
        and (expectedSerial == '' or linkedSerial == expectedSerial)
        and (expectedRestraintId == '' or linkedRestraint == '' or linkedRestraint == expectedRestraintId) then
        return {
          uid = rowUid,
          slot = tonumber(row.slot) or row.slot,
          metadata = copy(metadata)
        }
      end
    end
  end
  if sawKey then return nil, 'key_mismatch' end
  return nil, 'key_not_held'
end

local function consumeRestraintItem(source, itemName, instanceUid, operationId)
  if type(exports) ~= 'table' or not exports['mz_inventory'] then
    return false, 'inventory_unavailable'
  end
  local callOk, ok, value = pcall(function()
    return exports['mz_inventory']:ConsumeRestraintItem(source, itemName, instanceUid, operationId)
  end)
  if not callOk then return false, 'inventory_contract_failed' end
  if ok ~= true then return false, tostring(value or 'inventory_consume_failed') end
  return true, value
end

local function grantRestraintItem(source, itemName, metadata, operationId)
  if type(exports) ~= 'table' or not exports['mz_inventory'] then
    return false, 'inventory_unavailable'
  end
  local callOk, ok, value = pcall(function()
    return exports['mz_inventory']:GrantRestraintItem(source, itemName, metadata, operationId)
  end)
  if not callOk then return false, 'inventory_contract_failed' end
  if ok ~= true then return false, tostring(value or 'inventory_grant_failed') end
  return true, value
end

local function staffAllowed(actorSource, targetSource)
  if cfg().enableStaffCommand ~= true then return false, 'staff_command_disabled' end
  if type(exports) ~= 'table' or not exports['mz_core'] then
    return false, 'staff_permission_unavailable'
  end
  local permission = tostring(cfg().staffPermission or 'staff.restraints.manage')
  local permissionOk, allowed = pcall(function()
    return exports['mz_core']:HasGlobalPermission(actorSource, permission)
  end)
  if not permissionOk or allowed ~= true then return false, 'staff_permission_denied' end

  local hierarchyOk, canAct, hierarchyReason = pcall(function()
    return exports['mz_core']:CanStaffActOnPlayer(actorSource, targetSource)
  end)
  if not hierarchyOk or canAct ~= true then
    return false, 'staff_hierarchy_denied', hierarchyReason
  end

  local contextOk, context = pcall(function()
    return exports['mz_core']:GetStaffContext(actorSource)
  end)
  return true, permission, contextOk and context or nil
end

local function policeAllowed(actorSource)
  if type(MZPolice.Policy) ~= 'table' or type(MZPolice.Policy.authorize) ~= 'function' then
    return { ok = false, code = 'policy_unavailable' }
  end
  return MZPolice.Policy.authorize(
    actorSource,
    cfg().capability or MZPoliceConfig.Custody.capability
  )
end

local function hasAuthorizedOrganization(source)
  if not MZPolice.Bridge or type(MZPolice.Bridge.getPlayerOrganizations) ~= 'function' then
    return false
  end
  local organizations = MZPolice.Bridge.getPlayerOrganizations(source)
  if type(organizations) ~= 'table' then return false end
  local authorized = type(MZPoliceConfig.AuthorizedOrganizations) == 'table'
    and MZPoliceConfig.AuthorizedOrganizations or {}
  for _, organization in ipairs(organizations) do
    local code = tostring(
      organization.code or organization.orgCode or organization.org_code or ''
    ):lower()
    if authorized[code] == true then return true end
  end
  return false
end

local function resolveActor(actorSource, channel, targetSource)
  local identity, identityError = MZPolice.Bridge.resolveIdentity(actorSource)
  if not identity then return nil, identityError or 'identity_unavailable' end

  if channel == 'service' then
    if cfg().enablePoliceCommand ~= true then return nil, 'police_command_disabled' end
    -- Target policial: basta organizacao autorizada + duty. O servidor
    -- continua validando alvo, custodia, distancia, bucket e estado.
    local decision = MZPolice.Policy.authorizeDuty(actorSource)
    if decision.ok ~= true then return nil, decision.code or 'duty_required' end
    return {
      identity = identity,
      mode = 'service',
      authorization = decision,
      orgCode = decision.organization and decision.organization.code or 'police'
    }
  elseif channel == 'admin' then
    local allowed, permissionOrError, staffContext = staffAllowed(actorSource, targetSource)
    if allowed ~= true then return nil, permissionOrError end
    return {
      identity = identity,
      mode = 'admin',
      authorization = {
        ok = true,
        identity = identity,
        capability = tostring(permissionOrError),
        organization = { code = 'staff', duty = true }
      },
      staff = staffContext,
      orgCode = 'staff'
    }
  elseif channel == 'physical' then
    if cfg().civilianPhysicalCuffs ~= true then return nil, 'physical_cuffs_disabled' end
    if hasAuthorizedOrganization(actorSource) then
      local decision = policeAllowed(actorSource)
      if decision.ok == true then
        return {
          identity = identity,
          mode = 'physical',
          authorization = decision,
          police = true,
          orgCode = decision.organization and decision.organization.code or 'police'
        }
      end
    end
    return {
      identity = identity,
      mode = 'physical',
      authorization = {
        ok = true,
        identity = identity,
        capability = 'restraints.physical',
        organization = { code = 'civil', duty = true }
      },
      police = false,
      orgCode = 'civil'
    }
  end
  return nil, 'invalid_channel'
end

local function custodyRevision(targetSource)
  local state = MZPolice.Custody and MZPolice.Custody.get(targetSource) or nil
  return state and tonumber(state.revision) or 0
end

local function clearPending(entry)
  if not entry then return end
  local current = pending[entry.targetSource]
  if current and current.token == entry.token then pending[entry.targetSource] = nil end
  if pendingByActor[entry.actorSource] == entry.targetSource then pendingByActor[entry.actorSource] = nil end
end

local function sendResult(source, action, targetSource, response)
  TriggerClientEvent('mz_police:client:restraints:result', source, {
    action = action,
    targetSource = targetSource,
    response = response
  })
end

local function sendAnimation(entry, phase)
  local duration = entry.action == 'cuff'
    and (tonumber(cfg().animationDurationMs) or 1800)
    or (tonumber(cfg().removalDurationMs) or 900)
  TriggerClientEvent('mz_police:client:restraints:animation', entry.actorSource, {
    phase = phase,
    action = entry.action,
    actorSource = entry.actorSource,
    targetSource = entry.targetSource,
    origin = entry.mode,
    duration = duration
  })
  if entry.targetSource ~= entry.actorSource then
    TriggerClientEvent('mz_police:client:restraints:animation', entry.targetSource, {
      phase = phase,
      action = entry.action,
      actorSource = entry.actorSource,
      targetSource = entry.targetSource,
      origin = entry.mode,
      duration = duration
    })
  end
end

local function audit(action, actor, target, fields)
  fields = type(fields) == 'table' and fields or {}
  if fields.staffOverride == true and cfg().logStaffOverrides ~= false
    and type(TriggerEvent) == 'function' then
    TriggerEvent('mz_police:server:restraintStaffOverride', {
      action = tostring(action),
      actorCitizenid = actor and actor.citizenid or nil,
      targetCitizenid = target and target.citizenid or nil,
      origin = fields.origin,
      reason = fields.reason,
      restraintId = fields.restraintId,
      result = fields.result
    })
  end
  if MZPolice.Audit and type(MZPolice.Audit.restraint) == 'function' then
    MZPolice.Audit.restraint(action, actor, target, fields)
  end
end

local function sourceForCitizenid(citizenid)
  if not MZPolice.Bridge or type(MZPolice.Bridge.getSourceByCitizenId) ~= 'function' then return nil end
  local source = MZPolice.Bridge.getSourceByCitizenId(citizenid)
  return tonumber(source)
end

local function queueRestitution(citizenid, itemName, metadata, operationId, reason)
  citizenid = tostring(citizenid or '')
  if citizenid == '' then return false end
  restitution[citizenid] = restitution[citizenid] or {}
  restitution[citizenid][#restitution[citizenid] + 1] = {
    item = itemName,
    metadata = copy(metadata),
    operationId = operationId,
    reason = reason,
    createdAt = os.time()
  }
  return true
end

local function retryRestitution(citizenid, source)
  citizenid = tostring(citizenid or '')
  local list = restitution[citizenid]
  if not list or #list == 0 then return end
  source = tonumber(source or sourceForCitizenid(citizenid))
  if not source then return end

  local remaining = {}
  for _, entry in ipairs(list) do
    local ok = grantRestraintItem(source, entry.item, entry.metadata, entry.operationId)
    if not ok then remaining[#remaining + 1] = entry end
  end
  restitution[citizenid] = #remaining > 0 and remaining or nil
end

local function persistenceReady()
  return type(MZPolice.RestraintsRepository) == 'table'
    and type(MZPolice.RestraintsRepository.ready) == 'function'
    and MZPolice.RestraintsRepository.ready() == true
end

local function persistState(state, status)
  if not persistenceReady() or type(state) ~= 'table' then return false end
  return MZPolice.RestraintsRepository.upsert(state, status) == true
end

local function deletePersisted(citizenid)
  if not persistenceReady() then return false end
  return MZPolice.RestraintsRepository.remove(citizenid) == true
end

local function buildPersistedState(state, identity)
  local restraint = state.restraint or {}
  local actor = state.cuffedBy or {}
  local target = identity or state.target or {}
  return {
    revision = tonumber(state.revision) or 1,
    cuffed = true,
    target = copy(target),
    cuffedBy = copy(actor),
    restraint = copy(restraint)
  }
end

function Restraints.revision(targetSource)
  return custodyRevision(tonumber(targetSource))
end

function Restraints.get(targetSource)
  local state = MZPolice.Custody and MZPolice.Custody.get(targetSource) or nil
  if not state or state.cuffed ~= true then
    return { cuffed = false, revision = 0 }
  end
  local restraint = type(state.restraint) == 'table' and state.restraint or {}
  return {
    cuffed = true,
    revision = tonumber(state.revision) or 0,
    origin = tostring(restraint.origin or 'service'),
    serial = restraint.serial,
    keyIssued = restraint.keyUid ~= nil and restraint.keyUid ~= '',
    appliedAt = tonumber(restraint.appliedAt),
    persistent = restraint.persistent == true
  }
end

function Restraints.access(source)
  local rows = playerInventory(source)
  local handcuffs, keys = 0, 0
  for _, row in ipairs(rows or {}) do
    if tostring(row.item or '') == items().handcuffs and trim(row.instance_uid) ~= '' then
      handcuffs = handcuffs + 1
    elseif tostring(row.item or '') == items().key and trim(row.instance_uid) ~= '' then
      keys = keys + 1
    end
  end
  return {
    handcuffs = handcuffs,
    keys = keys,
    physicalEnabled = cfg().civilianPhysicalCuffs == true,
    serviceUnlock = cfg().policeServiceUnlock == true,
    serviceCuffsWithoutItem = cfg().policeServiceCuffsWithoutItem ~= false,
    requireSurrendered = cfg().civiliansRequireSurrenderedTarget ~= false,
    maximumDistance = tonumber(cfg().maximumDistance) or 2.0
  }
end

function Restraints.shouldPersistTargetOnDisconnect(state, reason)
  if not state or type(state.restraint) ~= 'table' then return false end
  if cfg().persistence == nil or cfg().persistence.enabled ~= true then return false end
  if state.restraint.origin ~= 'physical' or state.restraint.persistent ~= true then return false end
  if reason ~= 'player_dropped' and reason ~= 'target_session_changed' then return false end
  return true
end

function Restraints.shouldPersistActorOnDisconnect(state, reason)
  if not state or type(state.restraint) ~= 'table' then return false end
  if cfg().persistence == nil or cfg().persistence.enabled ~= true then return false end
  if state.restraint.origin ~= 'physical' or state.restraint.persistent ~= true then return false end
  if reason ~= 'player_dropped' then return false end
  return true
end

function Restraints.shouldKeepOnResourceStop(state)
  if not state or type(state.restraint) ~= 'table' then return false end
  if cfg().persistence == nil or cfg().persistence.enabled ~= true then return false end
  return state.restraint.origin == 'physical' and state.restraint.persistent == true
end

function Restraints.persistState(state, status)
  return persistState(state, status)
end

function Restraints.suspendTargetState(state, reason)
  if type(state) ~= 'table' then return false end
  state.restraint = type(state.restraint) == 'table' and state.restraint or {}
  if cfg().persistence == nil or cfg().persistence.enabled ~= true then return false end
  local citizenid = state.target and tostring(state.target.citizenid or '') or ''
  if citizenid ~= '' then suspended[citizenid] = copy(state) end
  persistState(state, 'offline')
  audit('suspended', state.cuffedBy, state.target, {
    origin = state.restraint.origin,
    restraintId = state.restraint.id,
    instanceUid = state.restraint.itemUid,
    serial = state.restraint.serial,
    result = 'suspended',
    reason = reason
  })
  return true
end

local function settleReleasedState(state, reason, options)
  local restraint = type(state.restraint) == 'table' and state.restraint or {}
  local settlement = type(options) == 'table' and options.settlement or restraint.settlement or {}
  local citizenid = state.target and tostring(state.target.citizenid or '') or ''
  if options.skipItemRestore == true or settlement.skipItemRestore == true then
    deletePersisted(citizenid)
    return
  end

  if restraint.origin ~= 'physical' or trim(restraint.itemUid) == '' then
    deletePersisted(citizenid)
    return
  end

  local restraintId = trim(restraint.id)
  if restraintId == '' then restraintId = makeId('restraint') end

  -- A chave emitida deixa de ser valida em qualquer liberacao forcada.
  -- O fluxo normal de unlock ja a consumiu antes de chamar a custodia.
  if trim(restraint.keyUid) ~= '' and settlement.keyConsumed ~= true then
    local holderSource = sourceForCitizenid(restraint.keyHolder)
    if holderSource then
      consumeRestraintItem(
        holderSource, items().key, restraint.keyUid, 'restraint:keycleanup:' .. restraintId
      )
    end
  end

  local restoreSource = tonumber(settlement.restoreTo)
    or tonumber(state.cuffedBy and state.cuffedBy.source)
  local restoreCitizenid = tostring(
    settlement.restoreCitizenid
      or (state.cuffedBy and state.cuffedBy.citizenid)
      or ''
  )

  local metadata = {
    uid = trim(restraint.itemUid),
    serial = trim(restraint.serial)
  }
  local restoreOperation = 'restraint:restore:' .. restraintId
  local delivered = false
  if restoreSource and restoreCitizenid ~= '' then
    local identity = MZPolice.Bridge.resolveIdentity(restoreSource)
    if identity and identity.citizenid == restoreCitizenid then
      delivered = grantRestraintItem(restoreSource, items().handcuffs, metadata, restoreOperation)
    end
  end
  if not delivered and restoreCitizenid ~= '' then
    queueRestitution(restoreCitizenid, items().handcuffs, metadata, restoreOperation, reason)
  end

  deletePersisted(citizenid)
  audit('released', state.cuffedBy, state.target, {
    origin = restraint.origin,
    restraintId = restraint.id,
    instanceUid = restraint.itemUid,
    serial = restraint.serial,
    keyInstanceUid = restraint.keyUid,
    result = delivered and 'item_restored' or 'item_restitution_pending',
    reason = reason
  })
end

function Restraints.onCustodyReleased(state, reason, options)
  options = type(options) == 'table' and options or {}
  if not state or type(state) ~= 'table' then return end
  local persistent = Restraints.shouldPersistTargetOnDisconnect(state, reason)
    or Restraints.shouldPersistActorOnDisconnect(state, reason)
  if persistent and (reason == 'player_dropped' or reason == 'target_session_changed') then
    Restraints.suspendTargetState(state, reason)
    return
  end
  settleReleasedState(state, reason, options)
end

local function validateCuff(actorSource, targetSource, mode, police)
  local targetState, targetError = MZPolice.Bridge.resolveIdentity(targetSource)
  if not targetState then return nil, targetError or 'target_offline' end
  local actorState, actorError = MZPolice.Bridge.resolveIdentity(actorSource)
  if not actorState then return nil, actorError or 'identity_unavailable' end

  -- Algema nao depende de situacao prisional ativa. Policial e qualquer
  -- portador de algema podem algemar um alvo valido; a sentenca e outro fluxo.
  local deathState, deathError = deathStateFor(targetSource)
  if not deathState then return nil, deathError or 'target_state_unavailable' end
  local allowDowned = mode == 'physical' or mode == 'admin'
  if mode == 'physical' and police ~= true and cfg().civiliansRequireSurrenderedTarget ~= false
    and deathState ~= 'downed' then
    return nil, 'target_not_surrendered'
  end
  if deathState ~= 'alive' and not (allowDowned and deathState == 'downed') then
    return nil, 'target_not_alive'
  end
  return { target = targetState, actor = actorState, deathState = deathState }
end

local function validateUncuff(actorSource, targetSource, mode)
  local custody = MZPolice.Custody and MZPolice.Custody.get(targetSource) or nil
  if not custody or custody.cuffed ~= true then return nil, 'not_cuffed' end
  local restraint = type(custody.restraint) == 'table' and custody.restraint or {}
  if mode == 'service' and cfg().policeServiceUnlock ~= true then
    local owner = custody.cuffedBy and tonumber(custody.cuffedBy.source) == tonumber(actorSource)
    if not owner then return nil, 'service_unlock_disabled' end
  end
  if mode == 'physical' then
    if restraint.origin ~= 'physical' then return nil, 'no_physical_key' end
    local key, keyError = findMatchingKey(actorSource, custody)
    if not key then return nil, keyError or 'key_not_held' end
    return { state = custody, restraint = restraint, key = key }
  end
  return { state = custody, restraint = restraint }
end

local function finalizeSuccess(entry, response, extra)
  clearPending(entry)
  local out = copy(response)
  for key, value in pairs(type(extra) == 'table' and extra or {}) do out[key] = value end
  remember(entry.actor, entry.request, out)
  if entry.async == true then
    sendResult(entry.actorSource, entry.action, entry.targetSource, out)
  end
  return out
end

local function finalizeFailure(entry, code, extra)
  clearPending(entry)
  local out = result(false, code, extra)
  remember(entry.actor, entry.request, out)
  if entry.async == true then
    sendResult(entry.actorSource, entry.action, entry.targetSource, out)
  end
  return out
end

local function completeApply(entry)
  local current = pending[entry.targetSource]
  if not current or current.token ~= entry.token then return nil end
  if nowMs() > entry.expiresAt then
    return finalizeFailure(entry, 'restraint_apply_timeout')
  end

  local actorNow, actorError = MZPolice.Bridge.resolveIdentity(entry.actorSource)
  if not actorNow or actorNow.sessionId ~= entry.actor.sessionId
    or actorNow.citizenid ~= entry.actor.citizenid then
    return finalizeFailure(entry, actorError or 'actor_session_changed')
  end
  local targetNow, targetError = MZPolice.Bridge.resolveIdentity(entry.targetSource)
  if not targetNow or targetNow.sessionId ~= entry.target.sessionId
    or targetNow.citizenid ~= entry.target.citizenid then
    return finalizeFailure(entry, targetError or 'target_session_changed')
  end
  local close, proximityError = validateProximity(entry.actorSource, entry.targetSource)
  if not close then return finalizeFailure(entry, proximityError) end

  local deathState, deathError = deathStateFor(entry.targetSource)
  if not deathState then return finalizeFailure(entry, deathError) end
  if deathState == 'dead' or deathState == 'respawning' then
    return finalizeFailure(entry, 'target_not_alive')
  end
  if entry.mode == 'physical' and entry.police ~= true
    and cfg().civiliansRequireSurrenderedTarget ~= false and deathState ~= 'downed' then
    return finalizeFailure(entry, 'target_not_surrendered')
  end
  if deathState ~= 'alive' and not ((entry.mode == 'physical' or entry.mode == 'admin')
    and deathState == 'downed') then
    return finalizeFailure(entry, 'target_not_alive')
  end

  local cuff
  if entry.mode == 'physical' then
    local found, findError = findHandcuffs(entry.actorSource, entry.request and entry.request.preferredUid)
    if not found then return finalizeFailure(entry, findError or 'cuff_item_required') end
    if found.uid ~= entry.cuff.uid or found.serial ~= entry.cuff.serial then
      return finalizeFailure(entry, 'cuff_changed')
    end
    cuff = found
    local consumed, consumeError = consumeRestraintItem(
      entry.actorSource,
      items().handcuffs,
      cuff.uid,
      'restraint:consume:' .. entry.restraintId
    )
    if not consumed then return finalizeFailure(entry, consumeError or 'cuff_consume_failed') end
  end

  local expectedRevision = custodyRevision(entry.targetSource)
  if expectedRevision ~= 0 then
    if cuff then
      grantRestraintItem(
        entry.actorSource, items().handcuffs,
        { uid = cuff.uid, serial = cuff.serial },
        'restraint:restore:' .. entry.restraintId .. ':rollback'
      )
    end
    return finalizeFailure(entry, 'already_cuffed', { revision = expectedRevision })
  end

  local restraint = {
    id = entry.restraintId,
    origin = entry.mode,
    actor = copy(entry.actor),
    appliedAt = os.time(),
    itemUid = cuff and cuff.uid or nil,
    serial = cuff and cuff.serial or nil,
    persistent = entry.mode == 'physical' and cfg().persistence ~= nil
      and cfg().persistence.enabled == true,
    reason = entry.reason
  }
  local response = MZPolice.Custody.requestAuthorized(entry.actorSource, {
    action = 'cuff',
    targetSource = entry.targetSource,
    requestId = entry.requestId,
    expectedRevision = 0
  }, entry.authorization, {
    origin = entry.mode,
    restraint = restraint,
    maximumDistance = cfg().maximumDistance,
    allowDownedTarget = entry.mode == 'physical' or entry.mode == 'admin',
    allowSelf = entry.mode == 'admin',
    reason = entry.reason
  })

  if response.ok ~= true then
    if cuff then
      grantRestraintItem(
        entry.actorSource, items().handcuffs,
        { uid = cuff.uid, serial = cuff.serial },
        'restraint:restore:' .. entry.restraintId .. ':rollback'
      )
    end
    audit('apply_failed', entry.actor, entry.target, {
      origin = entry.mode,
      restraintId = entry.restraintId,
      instanceUid = cuff and cuff.uid or nil,
      serial = cuff and cuff.serial or nil,
      result = response.code,
      reason = entry.reason,
      channel = entry.mode,
      command = entry.command,
      staffOverride = entry.mode == 'admin'
    })
    return finalizeFailure(entry, response.code, { revision = response.revision })
  end

  local issuedKey
  if entry.mode == 'physical' then
    local keyMetadata = {
      handcuff_uid = cuff.uid,
      cuff_serial = cuff.serial,
      restraint_id = entry.restraintId
    }
    local keyOk, keyResult = grantRestraintItem(
      entry.actorSource,
      items().key,
      keyMetadata,
      'restraint:key:' .. entry.restraintId
    )
    if not keyOk then
      -- Rollback integral: sem chave nao pode existir algema fisica "presa".
      local rollback = MZPolice.Custody.requestAuthorized(entry.actorSource, {
        action = 'uncuff',
        targetSource = entry.targetSource,
        requestId = entry.requestId .. ':rollback',
        expectedRevision = tonumber(response.revision) or 1
      }, entry.authorization, {
        origin = entry.mode,
        allowUncuff = true,
        allowDeadTarget = true,
        allowDownedTarget = true,
        skipItemRestore = true,
        settlement = { skipItemRestore = true, reason = 'key_grant_failed' },
        reason = 'key_grant_failed'
      })
      grantRestraintItem(
        entry.actorSource, items().handcuffs,
        { uid = cuff.uid, serial = cuff.serial },
        'restraint:restore:' .. entry.restraintId .. ':rollback'
      )
      audit('key_issue_failed', entry.actor, entry.target, {
        origin = entry.mode,
        restraintId = entry.restraintId,
        instanceUid = cuff.uid,
        serial = cuff.serial,
        result = rollback.ok == true and 'rolled_back' or 'rollback_failed',
        reason = tostring(keyResult or 'inventory_grant_failed')
      })
      return finalizeFailure(entry, 'key_inventory_full')
    end
    issuedKey = keyResult
    MZPolice.Custody.setRestraint(entry.targetSource, {
      keyUid = keyResult.instanceUid,
      keyHolder = entry.actor.citizenid,
      keySerial = type(keyResult.metadata) == 'table' and keyResult.metadata.serial or nil
    })
  end

  local newest = MZPolice.Custody.get(entry.targetSource)
  if newest then
    response.revision = tonumber(newest.revision) or response.revision
    local persisted = persistState(newest, 'active')
    if restraint.persistent == true and persisted ~= true then
      -- Fail closed: sem persistencia confiavel, desfaz a restricao e devolve
      -- os itens. Nunca finge que a algema sobrevivera a um restart.
      if issuedKey then
        consumeRestraintItem(
          entry.actorSource, items().key, issuedKey.instanceUid,
          'restraint:keyrollback:' .. entry.restraintId
        )
      end
      MZPolice.Custody.requestAuthorized(entry.actorSource, {
        action = 'uncuff',
        targetSource = entry.targetSource,
        requestId = entry.requestId .. ':persistence_rollback',
        expectedRevision = tonumber(newest.revision) or 1
      }, entry.authorization, {
        origin = entry.mode,
        allowUncuff = true,
        allowDeadTarget = true,
        allowDownedTarget = true,
        skipItemRestore = true,
        settlement = { skipItemRestore = true, reason = 'persistence_write_failed' },
        reason = 'persistence_write_failed'
      })
      grantRestraintItem(
        entry.actorSource, items().handcuffs,
        { uid = cuff.uid, serial = cuff.serial },
        'restraint:restore:' .. entry.restraintId .. ':persistence'
      )
      audit('persistence_failed', entry.actor, entry.target, {
        origin = entry.mode,
        restraintId = entry.restraintId,
        instanceUid = cuff.uid,
        serial = cuff.serial,
        result = 'rolled_back',
        reason = 'persistence_write_failed'
      })
      return finalizeFailure(entry, 'persistence_write_failed')
    end
  end

  audit('applied', entry.actor, entry.target, {
    origin = entry.mode,
    restraintId = entry.restraintId,
    instanceUid = cuff and cuff.uid or nil,
    serial = cuff and cuff.serial or nil,
    keyInstanceUid = issuedKey and issuedKey.instanceUid or nil,
    result = 'cuffed',
    reason = entry.reason,
    channel = entry.mode,
    command = entry.command,
    staffOverride = entry.mode == 'admin',
    revision = response.revision
  })

  TriggerClientEvent('mz_police:client:restraints:accessRefresh', entry.actorSource)
  return finalizeSuccess(entry, response, {
    restraint = issuedKey and {
      origin = entry.mode,
      serial = cuff and cuff.serial or nil,
      keyIssued = true
    } or { origin = entry.mode, serial = cuff and cuff.serial or nil, keyIssued = false }
  })
end

local function completeRemove(entry)
  local current = pending[entry.targetSource]
  if not current or current.token ~= entry.token then return nil end
  if nowMs() > entry.expiresAt then return finalizeFailure(entry, 'restraint_remove_timeout') end

  local actorNow, actorError = MZPolice.Bridge.resolveIdentity(entry.actorSource)
  if not actorNow or actorNow.sessionId ~= entry.actor.sessionId
    or actorNow.citizenid ~= entry.actor.citizenid then
    return finalizeFailure(entry, actorError or 'actor_session_changed')
  end
  local targetNow, targetError = MZPolice.Bridge.resolveIdentity(entry.targetSource)
  if not targetNow then return finalizeFailure(entry, targetError or 'target_offline') end
  local close, proximityError = validateProximity(entry.actorSource, entry.targetSource)
  if not close then return finalizeFailure(entry, proximityError) end

  local custody = MZPolice.Custody.get(entry.targetSource)
  if not custody or custody.cuffed ~= true then return finalizeFailure(entry, 'not_cuffed') end
  if tonumber(custody.revision) ~= tonumber(entry.expectedRevision) then
    return finalizeFailure(entry, 'revision_conflict', { revision = custody.revision })
  end

  local key
  if entry.mode == 'physical' then
    local found, keyError = findMatchingKey(entry.actorSource, custody)
    if not found then return finalizeFailure(entry, keyError or 'key_not_held') end
    key = found
    local consumed, consumeError = consumeRestraintItem(
      entry.actorSource,
      items().key,
      key.uid,
      'restraint:unlock:' .. tostring(custody.restraint and custody.restraint.id or entry.targetSource)
        .. ':' .. tostring(custody.revision)
    )
    if not consumed then return finalizeFailure(entry, consumeError or 'key_consume_failed') end
  elseif entry.mode == 'service' and cfg().policeServiceUnlock ~= true
    and not (custody.cuffedBy and tonumber(custody.cuffedBy.source) == entry.actorSource) then
    return finalizeFailure(entry, 'service_unlock_disabled')
  end

  local settlement = {
    restoreTo = entry.actorSource,
    restoreCitizenid = entry.actor.citizenid,
    keyConsumed = key ~= nil,
    reason = entry.reason
  }
  if entry.mode ~= 'physical' and custody.cuffedBy then
    settlement.restoreTo = tonumber(custody.cuffedBy.source)
    settlement.restoreCitizenid = tostring(custody.cuffedBy.citizenid or '')
  end
  local response = MZPolice.Custody.requestAuthorized(entry.actorSource, {
    action = 'uncuff',
    targetSource = entry.targetSource,
    requestId = entry.requestId,
    expectedRevision = tonumber(custody.revision) or 0
  }, entry.authorization, {
    origin = entry.mode,
    allowUncuff = true,
    allowDeadTarget = true,
    allowSelf = entry.mode == 'admin',
    settlement = settlement,
    maximumDistance = cfg().maximumDistance,
    reason = entry.reason
  })

  if response.ok ~= true then
    if key then
      grantRestraintItem(
        entry.actorSource, items().key, key.metadata,
        'restraint:keyrestore:' .. entry.restraintId .. ':' .. tostring(custody.revision)
      )
    end
    audit('remove_failed', entry.actor, custody.target, {
      origin = entry.mode,
      restraintId = entry.restraintId,
      keyInstanceUid = key and key.uid or nil,
      result = response.code,
      reason = entry.reason,
      channel = entry.mode,
      command = entry.command,
      staffOverride = entry.mode == 'admin'
    })
    return finalizeFailure(entry, response.code, { revision = response.revision })
  end

  audit('removed', entry.actor, custody.target, {
    origin = entry.mode,
    restraintId = entry.restraintId,
    keyInstanceUid = key and key.uid or nil,
    result = 'uncuffed',
    reason = entry.reason,
    channel = entry.mode,
    command = entry.command,
    staffOverride = entry.mode == 'admin',
    revision = response.revision
  })
  TriggerClientEvent('mz_police:client:restraints:accessRefresh', entry.actorSource)
  return finalizeSuccess(entry, response, { restraint = nil })
end

local function complete(entry)
  if entry.action == 'cuff' then return completeApply(entry) end
  return completeRemove(entry)
end

local function queueCompletion(entry)
  local delay = entry.action == 'cuff'
    and (tonumber(cfg().animationDurationMs) or 1800)
    or (tonumber(cfg().removalDurationMs) or 900)
  if delay <= 0 then
    entry.async = false
    return complete(entry)
  end
  if type(SetTimeout) == 'function' then
    SetTimeout(delay, function()
      local ok, err = pcall(complete, entry)
      if not ok then
        print(('[mz_police][restraints] completion failed safely: %s'):format(tostring(err)))
        finalizeFailure(entry, 'internal_error')
      end
    end)
    return result(true, 'restraint_pending', {
      pending = true,
      targetSource = entry.targetSource,
      action = entry.action
    })
  end
  entry.async = false
  return complete(entry)
end

function Restraints.request(actorSource, payload, channel)
  if cfg().enabled ~= true then return result(false, 'restraints_disabled') end
  actorSource = tonumber(actorSource)
  if not actorSource or actorSource <= 0 then return result(false, 'invalid_source') end
  channel = tostring(channel or 'service'):lower()
  local request, requestError = normalizePayload(payload)
  if not request then return result(false, requestError) end

  local actorInfo, actorError = resolveActor(actorSource, channel, request.targetSource)
  if not actorInfo then return result(false, actorError) end
  if request.targetSource == actorSource and actorInfo.mode ~= 'admin' then
    return result(false, 'self_target_forbidden')
  end
  if not rateAllowed(actorSource) then return result(false, 'rate_limited') end

  local replayed = replay(actorInfo.identity, request)
  if replayed then return replayed end
  if not cooldownAllowed(actorSource) then return result(false, 'cooldown') end

  if pending[request.targetSource] then return result(false, 'target_busy') end
  if pendingByActor[actorSource] then return result(false, 'operation_pending') end

  local target, targetError = MZPolice.Bridge.resolveIdentity(request.targetSource)
  if not target then return result(false, targetError or 'target_offline') end
  local close, proximityError = validateProximity(actorSource, request.targetSource)
  if not close then return result(false, proximityError) end

  local currentRevision = custodyRevision(request.targetSource)
  if request.action == 'cuff' and currentRevision ~= 0 then
    return result(false, 'already_cuffed', { revision = currentRevision })
  end
  if request.expectedRevision ~= currentRevision then
    return result(false, 'revision_conflict', { revision = currentRevision })
  end
  if actorInfo.mode == 'physical' and cfg().persistence ~= nil
    and cfg().persistence.enabled == true and not persistenceReady() then
    return result(false, 'persistence_unavailable')
  end

  local validated, validateError
  if request.action == 'cuff' then
    if currentRevision ~= 0 then return result(false, 'already_cuffed', { revision = currentRevision }) end
    validated, validateError = validateCuff(actorSource, request.targetSource, actorInfo.mode, actorInfo.police)
    if not validated then return result(false, validateError) end

    if actorInfo.mode == 'service' and cfg().policeServiceCuffsWithoutItem ~= true then
      return result(false, 'service_cuffs_disabled')
    end
    if actorInfo.mode == 'physical' then
      local handcuffs, handcuffError = findHandcuffs(actorSource, request.preferredUid)
      if not handcuffs then return result(false, handcuffError or 'cuff_item_required') end
      validated.handcuffs = handcuffs
    end
  else
    validated, validateError = validateUncuff(actorSource, request.targetSource, actorInfo.mode)
    if not validated then return result(false, validateError) end
  end

  local entry = {
    token = makeId('pending'),
    restraintId = makeId('restraint'),
    action = request.action,
    mode = actorInfo.mode,
    actorSource = actorSource,
    targetSource = request.targetSource,
    actor = copy(actorInfo.identity),
    target = copy(target),
    authorization = actorInfo.authorization,
    request = copy(request),
    requestId = request.requestId,
    expectedRevision = request.expectedRevision,
    reason = request.reason,
    command = request.command,
    police = actorInfo.police == true,
    staff = actorInfo.staff,
    orgCode = actorInfo.orgCode,
    cuff = validated and validated.handcuffs or nil,
    key = validated and validated.key or nil,
    expiresAt = nowMs() + (tonumber(cfg().applyTimeoutMs) or 6000),
    async = true
  }

  pending[request.targetSource] = entry
  pendingByActor[actorSource] = request.targetSource

  sendAnimation(entry, request.action == 'cuff' and 'apply_start' or 'remove_start')
  local immediate = queueCompletion(entry)
  if immediate and immediate.pending ~= true then
    entry.async = false
    return immediate
  end
  return immediate
end

function Restraints.forceCompleteForTests(targetSource)
  local entry = pending[tonumber(targetSource)]
  if not entry then return nil end
  entry.async = false
  return complete(entry)
end

function Restraints.onPlayerLoaded(source)
  source = tonumber(source)
  if not source or source <= 0 then return end
  local identity = MZPolice.Bridge.resolveIdentity(source)
  if not identity then return end

  local stored = suspended[identity.citizenid]
  if not stored and persistenceReady() then
    stored = MZPolice.RestraintsRepository.get(identity.citizenid)
  end
  if stored and type(stored) == 'table' then
    local storedCharacterId = tonumber(stored.target and stored.target.characterId)
    if not storedCharacterId or storedCharacterId == identity.characterId then
      stored.target = copy(identity)
      stored.cuffed = true
      stored.revision = math.max(1, tonumber(stored.revision) or 1)
      local restored = MZPolice.Custody.restore(source, stored)
      if restored == true then
        suspended[identity.citizenid] = nil
        persistState(stored, 'active')
        TriggerClientEvent('mz_police:client:restraints:restored', source, Restraints.get(source))
      end
    end
  end
  retryRestitution(identity.citizenid, source)
end

function Restraints.cleanupSource(source, reason)
  source = tonumber(source)
  if not source then return end
  local targets = {}
  for targetSource, entry in pairs(pending) do
    if entry.actorSource == source or entry.targetSource == source then
      targets[#targets + 1] = targetSource
    end
  end
  for _, targetSource in ipairs(targets) do
    local entry = pending[targetSource]
    if entry then
      clearPending(entry)
      audit('apply_cancelled', entry.actor, entry.target, {
        origin = entry.mode,
        restraintId = entry.restraintId,
        result = 'cancelled',
        reason = reason or 'player_dropped'
      })
    end
  end
  rateLimits[source] = nil
  lastActionAt[source] = nil
end

function Restraints.sweep()
  local current = nowMs()
  local expired = {}
  for targetSource, entry in pairs(pending) do
    if current > (tonumber(entry.expiresAt) or 0) then expired[#expired + 1] = targetSource end
  end
  for _, targetSource in ipairs(expired) do
    local entry = pending[targetSource]
    if entry then finalizeFailure(entry, 'restraint_timeout') end
  end

  cleanupRequestCache()
  local interval = tonumber(cfg().persistence and cfg().persistence.retryIntervalMs) or 30000
  if current - lastRestitutionSweep >= interval then
    lastRestitutionSweep = current
    for citizenid in pairs(restitution) do
      local source = sourceForCitizenid(citizenid)
      if source then retryRestitution(citizenid, source) end
    end
  end
end

function Restraints.start()
  if cfg().enabled ~= true then
    print('[mz_police][restraints] disabled by MZPoliceConfig.Restraints.enabled')
    return false
  end
  local persistence = type(cfg().persistence) == 'table' and cfg().persistence or {}
  if persistence.enabled == true and type(MZPolice.RestraintsRepository) == 'table'
    and type(MZPolice.RestraintsRepository.prepare) == 'function' then
    local ready, err = MZPolice.RestraintsRepository.prepare()
    if ready ~= true then
      print(('[mz_police][restraints] persistence disabled: %s'):format(tostring(err)))
    end
  end
  print(('[mz_police][restraints] ready persistence=%s staff_permission=%s'):format(
    tostring(persistenceReady()),
    tostring(cfg().staffPermission)
  ))
  return true
end

function Restraints.stop(reason)
  local targets = {}
  for targetSource in pairs(pending) do targets[#targets + 1] = targetSource end
  for _, targetSource in ipairs(targets) do
    local entry = pending[targetSource]
    if entry then
      clearPending(entry)
      audit('apply_cancelled', entry.actor, entry.target, {
        origin = entry.mode,
        restraintId = entry.restraintId,
        result = 'cancelled',
        reason = reason or 'resource_stop'
      })
    end
  end
  pending = {}
  pendingByActor = {}
end

MZPolice.Restraints = Restraints
