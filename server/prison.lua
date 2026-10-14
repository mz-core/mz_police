MZPolice = MZPolice or {}

local Prison = {}
local rateLimits = {}

local function trim(value)
  return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function token(value, minimum, maximum)
  value = trim(value)
  if #value < minimum or #value > maximum or not value:match('^[%w:_-]+$') then return nil end
  return value
end

local function closed(value, allowed)
  if type(value) ~= 'table' then return false end
  for key in pairs(value) do if not allowed[key] then return false end end
  return true
end

local function rateAllowed(source)
  local config, now = MZPoliceConfig.Prison.rateLimit or {}, GetGameTimer()
  local duration, maximum = tonumber(config.windowMs) or 5000, tonumber(config.maximum) or 6
  local window = rateLimits[source]
  if not window or now - window.startedAt >= duration then
    rateLimits[source] = { startedAt = now, count = 1 }
    return true
  end
  window.count = window.count + 1
  return window.count <= maximum
end

local function authorize(source, capability)
  if MZPoliceConfig.Prison.enabled ~= true then return nil, 'prison_integration_disabled' end
  if not rateAllowed(source) then return nil, 'rate_limited' end
  local decision = MZPolice.Policy.authorize(source, capability)
  return decision.ok == true and decision or nil, decision.code
end

local function proximity(leftSource, rightSource)
  if type(GetPlayerRoutingBucket) == 'function'
    and tonumber(GetPlayerRoutingBucket(leftSource)) ~= tonumber(GetPlayerRoutingBucket(rightSource)) then
    return false, 'routing_bucket_mismatch'
  end
  if type(GetPlayerPed) ~= 'function' or type(GetEntityCoords) ~= 'function' then return false, 'position_unavailable' end
  local leftPed, rightPed = GetPlayerPed(leftSource), GetPlayerPed(rightSource)
  if not leftPed or leftPed == 0 or not rightPed or rightPed == 0 then return false, 'position_unavailable' end
  local left, right = GetEntityCoords(leftPed), GetEntityCoords(rightPed)
  if not left or not right then return false, 'position_unavailable' end
  local lx, ly, lz = tonumber(left.x or left[1]), tonumber(left.y or left[2]), tonumber(left.z or left[3])
  local rx, ry, rz = tonumber(right.x or right[1]), tonumber(right.y or right[2]), tonumber(right.z or right[3])
  if not lx or not ly or not lz or not rx or not ry or not rz then return false, 'position_unavailable' end
  local dx, dy, dz = lx - rx, ly - ry, lz - rz
  local maximum = tonumber(MZPoliceConfig.Prison.maximumDistance) or 3.0
  return dx * dx + dy * dy + dz * dz <= maximum * maximum, 'target_too_far'
end

local function operationId(decision, requestId, prefix)
  requestId = token(requestId, 8, 32)
  if not requestId then return nil end
  local value = ('%s_%s_%s'):format(prefix, decision.identity.sessionId, requestId)
  return #value <= 64 and value or nil
end

function Prison.requestSentence(source, payload)
  if not closed(payload, { targetSource = true, caseId = true, ruleCode = true, requestId = true }) then
    return { ok = false, code = 'invalid_payload' }
  end
  local decision, authError = authorize(source, MZPoliceConfig.Prison.sentenceCapability)
  if not decision then return { ok = false, code = authError } end
  local targetSource = tonumber(payload.targetSource)
  local caseId, ruleCode = token(payload.caseId, 8, 160), token(payload.ruleCode, 2, 64)
  local operation = operationId(decision, payload.requestId, 'sentence')
  if not targetSource or targetSource <= 0 or targetSource == tonumber(source)
    or not caseId or not ruleCode or not operation then return { ok = false, code = 'invalid_sentence_request' } end
  local custody = MZPolice.Custody.get(targetSource)
  if not custody or custody.cuffed ~= true or not custody.cuffedBy
    or tonumber(custody.cuffedBy.source) ~= tonumber(source) then return { ok = false, code = 'custody_required' } end
  local close, proximityError = proximity(source, targetSource)
  if not close then return { ok = false, code = proximityError } end
  local targetCitizenid = custody.target and token(custody.target.citizenid, 2, 64) or nil
  if not targetCitizenid then return { ok = false, code = 'invalid_custody_identity' } end
  local case = MZPolice.RecordsRepository.getCase(decision.organization.code, caseId)
  if not case then return { ok = false, code = 'case_not_found' } end
  local sentenceCharge
  for _, charge in ipairs(case.charges or {}) do
    if tostring(charge.citizenid) == targetCitizenid and tostring(charge.rule_code) == ruleCode
      and (tonumber(charge.sentence_seconds) or 0) > 0 then
      sentenceCharge = charge
      break
    end
  end
  if not sentenceCharge then return { ok = false, code = 'sentence_charge_not_found' } end
  local result, sentenceError = MZPolice.Bridge.requestSentence(source, targetSource, {
    ruleCode = ruleCode, caseId = caseId, operationId = operation,
    orgCode = decision.organization.code
  })
  MZPolice.Audit.prison('sentence_request', decision.identity, {
    targetCitizenid = targetCitizenid, orgCode = decision.organization.code,
    caseId = caseId, operationId = operation,
    result = result and 'accepted' or 'denied', reason = sentenceError
  })
  if not result then return { ok = false, code = sentenceError } end
  MZPolice.Custody.cleanupSource(targetSource, 'prison_intake')
  return { ok = true, code = 'sentence_started', sentence = result }
end

function Prison.getSentence(source, payload)
  if not closed(payload, { citizenid = true }) then return { ok = false, code = 'invalid_payload' } end
  local decision, authError = authorize(source, MZPoliceConfig.Prison.readCapability)
  if not decision then return { ok = false, code = authError } end
  local citizenid = token(payload.citizenid, 2, 64)
  if not citizenid then return { ok = false, code = 'invalid_citizenid' } end
  local result, readError = MZPolice.Bridge.getSentence(citizenid)
  return result ~= nil and { ok = true, sentence = result } or { ok = false, code = readError }
end

function Prison.reduceSentence(source, payload)
  if not closed(payload, { citizenid = true, ruleCode = true, requestId = true }) then return { ok = false, code = 'invalid_payload' } end
  local decision, authError = authorize(source, MZPoliceConfig.Prison.reviewCapability)
  if not decision then return { ok = false, code = authError } end
  local citizenid, ruleCode = token(payload.citizenid, 2, 64), token(payload.ruleCode, 2, 64)
  local operation = operationId(decision, payload.requestId, 'reduction')
  if not citizenid or not ruleCode or not operation then return { ok = false, code = 'invalid_reduction_request' } end
  local result, reduceError = MZPolice.Bridge.reduceSentence(source, citizenid, {
    ruleCode = ruleCode, operationId = operation, orgCode = decision.organization.code
  })
  MZPolice.Audit.prison('reduction_request', decision.identity, {
    targetCitizenid = citizenid, orgCode = decision.organization.code,
    operationId = operation, result = result and 'accepted' or 'denied', reason = reduceError
  })
  return result and { ok = true, code = 'sentence_reduced', sentence = result }
    or { ok = false, code = reduceError }
end

function Prison.releasePrisoner(source, payload)
  if not closed(payload, { citizenid = true, reasonCode = true, requestId = true }) then return { ok = false, code = 'invalid_payload' } end
  local decision, authError = authorize(source, MZPoliceConfig.Prison.reviewCapability)
  if not decision then return { ok = false, code = authError } end
  local citizenid, reasonCode = token(payload.citizenid, 2, 64), token(payload.reasonCode, 2, 64)
  local operation = operationId(decision, payload.requestId, 'release')
  if not citizenid or not reasonCode or not operation then return { ok = false, code = 'invalid_release_request' } end
  local result, releaseError = MZPolice.Bridge.releasePrisoner(source, citizenid, {
    reasonCode = reasonCode, operationId = operation, orgCode = decision.organization.code
  })
  MZPolice.Audit.prison('release_request', decision.identity, {
    targetCitizenid = citizenid, orgCode = decision.organization.code,
    operationId = operation, result = result and 'accepted' or 'denied', reason = releaseError
  })
  return result and { ok = true, code = 'prisoner_released', sentence = result }
    or { ok = false, code = releaseError }
end

function Prison.cleanupSource(source) rateLimits[source] = nil end
function Prison.stop() rateLimits = {} end

MZPolice.Prison = Prison
