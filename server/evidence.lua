MZPolice = MZPolice or {}

local Evidence = {}
local rateLimits, terminals = {}, {}
local LIST_KEYS = { containerId = true }
local TRANSFER_KEYS = { fromContainer = true, toContainer = true, instanceUid = true, requestId = true }

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

function Evidence.list(source, payload)
  if not closed(payload, LIST_KEYS) then return { ok = false, code = 'invalid_payload' } end
  if not rateAllowed(source) then return { ok = false, code = 'rate_limited' } end
  local containerId = container(payload.containerId)
  if not containerId then return { ok = false, code = 'evidence_container_not_configured' } end
  local decision, authErr = authorize(source, MZPoliceConfig.Evidence.listCapability)
  if not decision then return { ok = false, code = authErr } end
  local items, listErr = MZPolice.Bridge.listPoliceEvidence(source, decision.organization.code, containerId)
  if not items then return { ok = false, code = listErr } end
  return { ok = true, action = 'list', containerId = containerId, items = items }
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

MZPolice.Evidence = Evidence
