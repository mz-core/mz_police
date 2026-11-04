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

local function fingerprint(...)
  local hash = 2166136261
  for index = 1, select('#', ...) do
    local value = tostring(select(index, ...) or '')
    for offset = 1, #value do hash = ((hash ~ value:byte(offset)) * 16777619) & 0xffffffff end
    hash = ((hash ~ 31) * 16777619) & 0xffffffff
  end
  return ('%08x'):format(hash)
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

local function processingPoint(source)
  local config = type(MZPoliceConfig.Prison) == 'table' and MZPoliceConfig.Prison or {}
  if config.processingEnabled ~= true or type(config.processingPoints) ~= 'table'
    or next(config.processingPoints) == nil then return nil, 'processing_not_configured' end
  if type(GetPlayerPed) ~= 'function' or type(GetEntityCoords) ~= 'function'
    or type(GetPlayerRoutingBucket) ~= 'function' then return nil, 'position_unavailable' end
  local ped = GetPlayerPed(source)
  local coords = ped and ped > 0 and GetEntityCoords(ped) or nil
  local x, y, z = coords and tonumber(coords.x or coords[1]), coords and tonumber(coords.y or coords[2]),
    coords and tonumber(coords.z or coords[3])
  local bucket = tonumber(GetPlayerRoutingBucket(source))
  if not x or not y or not z or bucket == nil then return nil, 'position_unavailable' end
  for pointId, point in pairs(config.processingPoints) do
    local target = type(point) == 'table' and point.coords or nil
    local radius = type(point) == 'table' and tonumber(point.radius) or nil
    local pointBucket = type(point) == 'table' and tonumber(point.routingBucket) or nil
    if point.enabled == true and type(target) == 'table' and tonumber(target.x) and tonumber(target.y)
      and tonumber(target.z) and radius and radius > 0 and radius <= 25
      and pointBucket and pointBucket >= 0 and pointBucket % 1 == 0 and bucket == pointBucket
      and ((x - tonumber(target.x)) ^ 2 + (y - tonumber(target.y)) ^ 2
        + (z - tonumber(target.z)) ^ 2) <= radius ^ 2 then
      return tostring(pointId)
    end
  end
  return nil, 'processing_point_required'
end

function Prison.processingContext(actorSource, targetSource)
  local close, proximityError = proximity(actorSource, targetSource)
  if not close then return nil, proximityError end
  local actorPoint, actorError = processingPoint(actorSource)
  if not actorPoint then return nil, actorError end
  local targetPoint, targetError = processingPoint(targetSource)
  if not targetPoint then return nil, targetError end
  if actorPoint ~= targetPoint then return nil, 'processing_point_mismatch' end
  return { pointId = actorPoint }
end

local function operationId(decision, requestId, prefix)
  requestId = token(requestId, 8, 32)
  if not requestId then return nil end
  local value = ('%s_%s_%s'):format(prefix, decision.identity.sessionId, requestId)
  return #value <= 64 and value or nil
end

function Prison.requestSentence(source, payload)
  if not closed(payload, { targetSource = true, caseId = true, chargeId = true, requestId = true }) then
    return { ok = false, code = 'invalid_payload' }
  end
  local decision, authError = authorize(source, MZPoliceConfig.Prison.sentenceCapability)
  if not decision then return { ok = false, code = authError } end

  local targetSource = tonumber(payload.targetSource)
  local caseId = token(payload.caseId, 8, 160)
  local requestedChargeId = token(payload.chargeId, 8, 160)
  local requestOperation = operationId(decision, payload.requestId, 'sentence')
  if not targetSource or targetSource <= 0 or targetSource == tonumber(source)
    or not caseId or not requestOperation then return { ok = false, code = 'invalid_sentence_request' } end

  local custody = MZPolice.Custody.get(targetSource)
  if not custody or custody.cuffed ~= true or not custody.cuffedBy
    or tonumber(custody.cuffedBy.source) ~= tonumber(source) then return { ok = false, code = 'custody_required' } end
  local close, proximityError = proximity(source, targetSource)
  if not close then return { ok = false, code = proximityError } end
  local targetCitizenid = custody.target and token(custody.target.citizenid, 2, 64) or nil
  if not targetCitizenid then return { ok = false, code = 'invalid_custody_identity' } end

  local case = MZPolice.RecordsRepository.getCase(decision.organization.code, caseId)
  if not case then return { ok = false, code = 'case_not_found' } end

  local selected = {}
  for _, charge in ipairs(case.charges or {}) do
    local matchesCitizen = tostring(charge.citizenid) == targetCitizenid
    local matchesCharge = requestedChargeId == nil or tostring(charge.public_id) == requestedChargeId
    if matchesCitizen and matchesCharge and (tonumber(charge.sentence_seconds) or 0) > 0 then
      selected[#selected + 1] = charge
      if requestedChargeId ~= nil then break end
    end
  end
  if #selected == 0 then return { ok = false, code = 'sentence_charge_not_found' } end
  if #selected > 1 and (type(MZPoliceConfig.Arrest) ~= 'table'
    or MZPoliceConfig.Arrest.multiChargeEnabled ~= true) then
    return { ok = false, code = 'multi_charge_disabled' }
  end

  local snapshots = {}
  for _, sentenceCharge in ipairs(selected) do
    local chargeId = token(sentenceCharge.public_id, 8, 160)
    local ruleCode = token(sentenceCharge.rule_code, 2, 64)
    local ruleName = trim(sentenceCharge.rule_name)
    local legalVersion = trim(sentenceCharge.legal_version)
    local sentenceSeconds = math.floor(tonumber(sentenceCharge.sentence_seconds) or 0)
    if not chargeId or not ruleCode or ruleName == '' or #ruleName > 160
      or legalVersion == '' or #legalVersion > 64 or sentenceSeconds <= 0 then
      return { ok = false, code = 'sentence_charge_invalid' }
    end
    snapshots[#snapshots + 1] = {
      chargeId = chargeId, ruleCode = ruleCode, ruleName = ruleName,
      sentenceSeconds = sentenceSeconds, legalVersion = legalVersion
    }
  end

  local result, sentenceError
  local auditFields = {
    targetCitizenid = targetCitizenid, orgCode = decision.organization.code,
    caseId = caseId, result = 'requested'
  }
  if #snapshots == 1 then
    local snapshot = snapshots[1]
    local singleOperation = 'sentence:' .. fingerprint(caseId, snapshot.chargeId)
    auditFields.chargeId = snapshot.chargeId
    auditFields.ruleCode = snapshot.ruleCode
    auditFields.operationId = singleOperation
    result, sentenceError = MZPolice.Bridge.requestSentence(source, targetSource, {
      chargeId = snapshot.chargeId, ruleCode = snapshot.ruleCode, ruleName = snapshot.ruleName,
      sentenceSeconds = snapshot.sentenceSeconds, legalVersion = snapshot.legalVersion,
      caseId = caseId, operationId = singleOperation, orgCode = decision.organization.code
    })
  else
    local ids = {}
    for _, snapshot in ipairs(snapshots) do ids[#ids + 1] = snapshot.chargeId end
    table.sort(ids)
    local multiOperation = 'sentence:' .. fingerprint(caseId, table.concat(ids, ','))
    auditFields.operationId = multiOperation
    auditFields.chargeCount = #snapshots
    result, sentenceError = MZPolice.Bridge.requestSentenceFromCharges(source, targetSource, {
      caseId = caseId, primaryChargeId = snapshots[1].chargeId, charges = snapshots,
      operationId = multiOperation, orgCode = decision.organization.code
    })
  end

  MZPolice.Audit.prison('sentence_request', decision.identity, {
    targetCitizenid = targetCitizenid, orgCode = decision.organization.code,
    caseId = caseId, chargeId = auditFields.chargeId, ruleCode = auditFields.ruleCode,
    operationId = auditFields.operationId, chargeCount = auditFields.chargeCount,
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
