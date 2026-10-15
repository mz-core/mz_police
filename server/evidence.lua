MZPolice = MZPolice or {}

local Evidence = {}
local rateLimits, terminals, locks = {}, {}, {}
local LIST_KEYS = { containerId = true }
local TRANSFER_KEYS = { fromContainer = true, toContainer = true, instanceUid = true, requestId = true }
local LINK_KEYS = { caseId = true, containerId = true, instanceUid = true, requestId = true }

local function copy(value)
  if type(value) ~= 'table' then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = copy(item) end
  return out
end
local function trim(value) return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '') end
local function key(value)
  value = trim(value):lower()
  return #value >= 2 and #value <= 48 and value:match('^[a-z0-9_-]+$') and value or nil
end
local function closed(payload, allowed)
  if type(payload) ~= 'table' then return false end
  for field in pairs(payload) do if not allowed[field] then return false end end
  return true
end
local function container(value)
  local id = key(value)
  local config = id and MZPoliceConfig.Evidence.containers[id] or nil
  return type(config) == 'table' and config.enabled ~= false and id or nil
end
local function rateAllowed(source)
  local config, now = MZPoliceConfig.Evidence.rateLimit or {}, GetGameTimer()
  local window = rateLimits[source]
  local duration, maximum = tonumber(config.windowMs) or 5000, tonumber(config.maximum) or 8
  if not window or now - window.startedAt >= duration then rateLimits[source] = { startedAt = now, count = 1 }; return true end
  window.count = window.count + 1
  return window.count <= maximum
end
local function authorize(source, capability)
  local decision = MZPolice.Policy.authorize(source, capability)
  return decision.ok == true and decision or nil, decision.code
end

local function token(value, minimum, maximum)
  value = trim(value)
  return #value >= minimum and #value <= maximum and value:match('^[%w:_-]+$') and value or nil
end

local function fingerprint(...)
  local hash = 2166136261
  for index = 1, select('#', ...) do
    local value = tostring(select(index, ...) or '')
    for offset = 1, #value do hash = ((hash ~ value:byte(offset)) * 16777619) & 0xffffffff end
    hash = ((hash ~ 31) * 16777619) & 0xffffffff
  end
  return ('%08x'):format(hash)
end

local function withLock(lockKey, callback)
  if locks[lockKey] then return { ok = false, code = 'operation_busy' } end
  locks[lockKey] = true
  local packed = table.pack(pcall(callback))
  locks[lockKey] = nil
  if packed[1] ~= true then return { ok = false, code = 'operation_failed' } end
  return table.unpack(packed, 2, packed.n)
end

function Evidence.list(source, payload)
  if not closed(payload, LIST_KEYS) then return { ok = false, code = 'invalid_payload' } end
  if not rateAllowed(source) then return { ok = false, code = 'rate_limited' } end
  local containerId = container(payload.containerId)
  if not containerId then return { ok = false, code = 'evidence_container_not_configured' } end
  local decision, authErr = authorize(source, MZPoliceConfig.Evidence.listCapability)
  if not decision then return { ok = false, code = authErr } end
  local items, listErr = MZPolice.Bridge.listPoliceEvidence(source, decision.organization.code, containerId)
  if not items then return { ok = false, code = listErr } end
  return {
    ok = true, action = 'list', containerId = containerId, items = items,
    associationEnabled = MZPoliceConfig.Evidence.occurrenceAssociationEnabled == true
  }
end

function Evidence.linkCase(source, payload)
  if not closed(payload, LINK_KEYS) then return { ok = false, code = 'invalid_payload' } end
  if MZPoliceConfig.Evidence.occurrenceAssociationEnabled ~= true then
    return { ok = false, code = 'evidence_association_disabled' }
  end
  if not MZPolice.RecordsPrepare.ready then return { ok = false, code = 'records_unavailable' } end
  if not rateAllowed(source) then return { ok = false, code = 'rate_limited' } end
  local caseId = token(payload.caseId, 8, 160)
  local containerId = container(payload.containerId)
  local instanceUid = token(payload.instanceUid, 1, 64)
  local requestId = token(payload.requestId, 8, 40)
  if not caseId or not containerId or not instanceUid or not requestId then
    return { ok = false, code = 'invalid_evidence_link' }
  end
  local decision, authErr = authorize(source, MZPoliceConfig.Evidence.manageCapability)
  if not decision then return { ok = false, code = authErr } end
  local policeCase = MZPolice.RecordsRepository.getCase(decision.organization.code, caseId)
  if not policeCase then return { ok = false, code = 'case_not_found' } end
  local operationId = ('evidence_link:%s:%s'):format(decision.identity.citizenid, requestId)
  local requestFingerprint = fingerprint(decision.organization.code, caseId, containerId, instanceUid)

  return withLock(operationId, function()
    local history = MZPolice.RecordsRepository.getHistoryOperation(operationId)
    if history then
      if tostring(history.request_fingerprint or '') ~= requestFingerprint then
        return { ok = false, code = 'request_id_conflict' }
      end
      return {
        ok = true, action = 'link', code = 'evidence_linked', replayed = true,
        case = MZPolice.RecordsRepository.getCase(decision.organization.code, caseId)
      }
    end
    local items, listErr = MZPolice.Bridge.listPoliceEvidence(source, decision.organization.code, containerId)
    if not items then return { ok = false, code = listErr } end
    local selected
    for _, item in ipairs(items) do
      if tostring(item.instanceUid or '') == instanceUid then selected = item; break end
    end
    local metadata = selected and type(selected.evidence) == 'table' and selected.evidence or nil
    local evidenceId = metadata and token(metadata.evidenceId, 8, 160) or nil
    local itemName = selected and token(selected.item, 1, 64) or nil
    local amount = selected and tonumber(selected.amount) or nil
    if not selected or not evidenceId or tostring(metadata.orgCode or '') ~= decision.organization.code
      or tostring(metadata.containerId or '') ~= containerId or not itemName
      or not amount or amount <= 0 or amount % 1 ~= 0 then
      return { ok = false, code = 'evidence_not_found' }
    end
    if MZPolice.RecordsRepository.getCaseEvidence(caseId, evidenceId) then
      return { ok = false, code = 'evidence_already_linked' }
    end
    local saved = MZPolice.RecordsRepository.linkCaseEvidence({
      caseId = caseId, orgCode = decision.organization.code, evidenceId = evidenceId,
      instanceUid = instanceUid, item = itemName,
      label = tostring(selected.label or selected.item or ''):sub(1, 160),
      amount = amount,
      containerId = containerId,
      evidenceRevision = math.max(1, math.floor(tonumber(metadata.revision) or 1)),
      actorCitizenid = decision.identity.citizenid,
      history = {
        operationId = operationId, orgCode = decision.organization.code,
        entityType = 'case', entityId = caseId, action = 'evidence_linked',
        actorCitizenid = decision.identity.citizenid, requestFingerprint = requestFingerprint,
        details = {
          evidenceId = evidenceId, instanceUid = instanceUid, containerId = containerId,
          evidenceRevision = math.max(1, math.floor(tonumber(metadata.revision) or 1))
        }
      }
    })
    if not saved then return { ok = false, code = 'persistence_failed' } end
    MZPolice.Audit.evidence('case_link', decision.identity, {
      orgCode = decision.organization.code, operationId = operationId, instanceUid = instanceUid,
      fromContainer = containerId, result = 'linked'
    })
    return {
      ok = true, action = 'link', code = 'evidence_linked',
      case = MZPolice.RecordsRepository.getCase(decision.organization.code, caseId)
    }
  end)
end

function Evidence.transfer(source, payload)
  if not closed(payload, TRANSFER_KEYS) then return { ok = false, code = 'invalid_payload' } end
  if not rateAllowed(source) then return { ok = false, code = 'rate_limited' } end
  local fromContainer, toContainer = container(payload.fromContainer), container(payload.toContainer)
  local instanceUid, requestId = trim(payload.instanceUid), trim(payload.requestId)
  if not fromContainer or not toContainer or fromContainer == toContainer then
    return { ok = false, code = 'invalid_evidence_container' }
  end
  if instanceUid == '' or #instanceUid > 64 or not instanceUid:match('^[%w:_-]+$')
    or #requestId < 8 or #requestId > 96 or not requestId:match('^[%w:_-]+$') then
    return { ok = false, code = 'invalid_evidence_transfer' }
  end
  local bucket = terminals[source] or {}; terminals[source] = bucket
  local fingerprint = table.concat({ fromContainer, toContainer, instanceUid }, ':')
  if bucket[requestId] then
    if bucket[requestId].fingerprint ~= fingerprint then return { ok = false, code = 'request_id_conflict' } end
    return copy(bucket[requestId].response)
  end
  local decision, authErr = authorize(source, MZPoliceConfig.Evidence.manageCapability)
  if not decision then return { ok = false, code = authErr } end
  local operationId = ('evidence:%s:%s'):format(decision.identity.sessionId, requestId)
  local result, transferErr = MZPolice.Bridge.transferPoliceEvidence(
    source, decision.organization.code, fromContainer, toContainer, instanceUid, operationId
  )
  MZPolice.Audit.evidence('transfer', decision.identity, {
    orgCode = decision.organization.code, operationId = operationId, instanceUid = instanceUid,
    fromContainer = fromContainer, toContainer = toContainer,
    result = result and 'transferred' or 'denied', reason = transferErr
  })
  local response = result and { ok = true, action = 'transfer', code = 'evidence_transferred', result = result }
    or { ok = false, code = transferErr }
  bucket[requestId] = { fingerprint = fingerprint, response = copy(response), createdAt = GetGameTimer() }
  return response
end

function Evidence.cleanupSource(source) rateLimits[source], terminals[source] = nil, nil end
function Evidence.sweep()
  local cutoff = GetGameTimer() - (tonumber(MZPoliceConfig.Evidence.requestRetentionMs) or 120000)
  for source, bucket in pairs(terminals) do
    for requestId, value in pairs(bucket) do if value.createdAt < cutoff then bucket[requestId] = nil end end
    if not next(bucket) then terminals[source] = nil end
  end
end

function Evidence.stop() rateLimits, terminals, locks = {}, {}, {} end

MZPolice.Evidence = Evidence
