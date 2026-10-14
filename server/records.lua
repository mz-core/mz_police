MZPolice = MZPolice or {}

local Records = {}
local rateLimits, locks = {}, {}
local CASE_KINDS = { occurrence = true, investigation = true, case = true }
local PERSON_ROLES = { subject = true, victim = true, witness = true, related = true }
local WARRANT_REVIEWS = { approve = 'approved', cancel = 'cancelled' }

local function trim(value)
  return tostring(value or ''):gsub('%c', ' '):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
end

local function token(value, minimum, maximum)
  value = trim(value)
  if #value < minimum or #value > maximum or not value:match('^[%w:_-]+$') then return nil end
  return value
end

local function closed(payload, allowed)
  if type(payload) ~= 'table' then return false end
  for field in pairs(payload) do if not allowed[field] then return false end end
  return true
end

local function rateAllowed(source)
  local config, now = MZPoliceConfig.Records.rateLimit or {}, GetGameTimer()
  local duration, maximum = tonumber(config.windowMs) or 5000, tonumber(config.maximum) or 12
  local window = rateLimits[source]
  if not window or now - window.startedAt >= duration then
    rateLimits[source] = { startedAt = now, count = 1 }
    return true
  end
  window.count = window.count + 1
  return window.count <= maximum
end

local function authorize(source, capability)
  if not MZPolice.RecordsPrepare.ready then return nil, 'records_unavailable' end
  if not rateAllowed(source) then return nil, 'rate_limited' end
  local decision = MZPolice.Policy.authorize(source, capability)
  return decision.ok == true and decision or nil, decision.code
end

local function withLock(lockKey, callback)
  if locks[lockKey] then return { ok = false, code = 'operation_busy' } end
  locks[lockKey] = true
  local packed = table.pack(pcall(callback))
  locks[lockKey] = nil
  if packed[1] ~= true then return { ok = false, code = 'operation_failed' } end
  return table.unpack(packed, 2, packed.n)
end

local function operation(decision, action, requestId)
  requestId = token(requestId, 8, 40)
  if not requestId then return nil end
  return ('%s:%s:%s'):format(action, decision.identity.citizenid, requestId), requestId
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

local function replayed(operationId, requestFingerprint)
  local row = MZPolice.RecordsRepository.getHistoryOperation(operationId)
  if not row then return false end
  if tostring(row.request_fingerprint or row.requestFingerprint or '') ~= requestFingerprint then
    return nil, 'request_id_conflict'
  end
  return true
end

local function history(decision, operationId, entityType, entityId, action, targetCitizenid, details, requestFingerprint)
  return {
    operationId = operationId, orgCode = decision.organization.code,
    entityType = entityType, entityId = entityId, action = action,
    actorCitizenid = decision.identity.citizenid, targetCitizenid = targetCitizenid,
    details = details, requestFingerprint = requestFingerprint
  }
end

local function configuredRule(section, orgCode, ruleCode)
  local config = MZPoliceConfig.Records
  if config.legalRulesEnabled ~= true then return nil, 'legal_rules_disabled' end
  local jurisdiction = type(config.jurisdictions) == 'table' and config.jurisdictions[orgCode] or nil
  if type(jurisdiction) ~= 'table' or jurisdiction.enabled ~= true then return nil, 'jurisdiction_disabled' end
  ruleCode = token(ruleCode, 2, 64)
  local catalog = type(config[section]) == 'table' and config[section] or {}
  if section == 'warrants' then catalog = type(catalog.rules) == 'table' and catalog.rules or {} end
  local rule = ruleCode and catalog[ruleCode] or nil
  if type(rule) ~= 'table' or rule.enabled ~= true then return nil, 'legal_rule_not_configured' end
  local name = trim(rule.name or rule.label)
  if name == '' or #name > 160 then return nil, 'legal_rule_invalid' end
  return {
    code = ruleCode, name = name,
    fineAmount = math.floor(tonumber(rule.fineAmount) or 0),
    sentenceSeconds = math.floor(tonumber(rule.sentenceSeconds) or 0)
  }
end

local function getCase(decision, caseId)
  caseId = token(caseId, 8, 160)
  if not caseId then return nil, 'invalid_case_id' end
  local case = MZPolice.RecordsRepository.getCase(decision.organization.code, caseId)
  if not case then return nil, 'case_not_found' end
  return case, nil, caseId
end

local function citizen(citizenid)
  citizenid = token(citizenid, 2, 64)
  if not citizenid then return nil, 'invalid_citizenid' end
  local character, characterError = MZPolice.Bridge.getCharacterByCitizenId(citizenid)
  if not character then return nil, characterError end
  return character, nil, citizenid
end

local function audit(action, decision, fields)
  fields.orgCode = decision.organization.code
  MZPolice.Audit.records(action, decision.identity, fields)
end

function Records.searchCitizens(source, payload)
  if not closed(payload, { query = true, page = true, pageSize = true }) then return { ok = false, code = 'invalid_payload' } end
  local decision, authError = authorize(source, MZPoliceConfig.Records.readCapability)
  if not decision then return { ok = false, code = authError } end
  local query = trim(payload.query):sub(1, 64)
  if #query < 2 then return { ok = false, code = 'invalid_search' } end
  local page = math.max(1, math.floor(tonumber(payload.page) or 1))
  local maximum = tonumber(MZPoliceConfig.Records.maximumPageSize) or 50
  local pageSize = math.max(1, math.min(maximum, math.floor(tonumber(payload.pageSize) or MZPoliceConfig.Records.pageSize or 25)))
  local result, searchError = MZPolice.Bridge.searchCharacters(query, page, pageSize)
  audit('citizen_search', decision, { result = result and 'read' or 'denied', reason = searchError })
  return result and { ok = true, result = result } or { ok = false, code = searchError }
end

function Records.getCitizen(source, payload)
  if not closed(payload, { citizenid = true }) then return { ok = false, code = 'invalid_payload' } end
  local decision, authError = authorize(source, MZPoliceConfig.Records.readCapability)
  if not decision then return { ok = false, code = authError } end
  local character, citizenError, citizenid = citizen(payload.citizenid)
  if not character then return { ok = false, code = citizenError } end
  local context = MZPolice.RecordsRepository.getCitizenContext(decision.organization.code, citizenid)
  audit('citizen_read', decision, { targetCitizenid = citizenid, result = 'read' })
  return { ok = true, citizen = character, police = context }
end

function Records.upsertRecord(source, payload)
  if not closed(payload, { citizenid = true, notes = true, requestId = true }) then return { ok = false, code = 'invalid_payload' } end
  local decision, authError = authorize(source, MZPoliceConfig.Records.writeCapability)
  if not decision then return { ok = false, code = authError } end
  local character, citizenError, citizenid = citizen(payload.citizenid)
  if not character then return { ok = false, code = citizenError } end
  local notes = trim(payload.notes)
  if #notes > 4000 then return { ok = false, code = 'record_notes_too_long' } end
  local operationId = operation(decision, 'record', payload.requestId)
  if not operationId then return { ok = false, code = 'invalid_request_id' } end
  local requestFingerprint = fingerprint(citizenid, notes)
  return withLock(operationId, function()
    local wasReplayed, replayError = replayed(operationId, requestFingerprint)
    if wasReplayed == nil then return { ok = false, code = replayError } end
    if not wasReplayed then
      local saved = MZPolice.RecordsRepository.upsertRecord({
        orgCode = decision.organization.code, citizenid = citizenid, notes = notes,
        actorCitizenid = decision.identity.citizenid,
        history = history(decision, operationId, 'citizen', citizenid, 'record_updated', citizenid, nil, requestFingerprint)
      })
      if not saved then return { ok = false, code = 'persistence_failed' } end
    end
    local record = MZPolice.RecordsRepository.getRecord(decision.organization.code, citizenid)
    audit('record_update', decision, { operationId = operationId, targetCitizenid = citizenid, result = 'updated' })
    return { ok = true, code = 'record_updated', record = record }
  end)
end

function Records.createCase(source, payload)
  if not closed(payload, { kind = true, title = true, summary = true, requestId = true }) then return { ok = false, code = 'invalid_payload' } end
  local decision, authError = authorize(source, MZPoliceConfig.Records.writeCapability)
  if not decision then return { ok = false, code = authError } end
  local kind, title, summary = trim(payload.kind):lower(), trim(payload.title), trim(payload.summary)
  if not CASE_KINDS[kind] or #title < 3 or #title > 160 or #summary > 8000 then
    return { ok = false, code = 'invalid_case' }
  end
  local operationId, requestId = operation(decision, 'case', payload.requestId)
  if not operationId then return { ok = false, code = 'invalid_request_id' } end
  local publicId = ('case:%s:%s'):format(decision.identity.citizenid, requestId)
  local requestFingerprint = fingerprint(kind, title, summary)
  return withLock(operationId, function()
    local wasReplayed, replayError = replayed(operationId, requestFingerprint)
    if wasReplayed == nil then return { ok = false, code = replayError } end
    if not wasReplayed then
      local saved = MZPolice.RecordsRepository.createCase({
        publicId = publicId, orgCode = decision.organization.code, kind = kind,
        title = title, summary = summary, actorCitizenid = decision.identity.citizenid,
        history = history(decision, operationId, 'case', publicId, 'case_created', nil, nil, requestFingerprint)
      })
      if not saved then return { ok = false, code = 'persistence_failed' } end
    end
    audit('case_create', decision, { operationId = operationId, caseId = publicId, result = 'created' })
    return { ok = true, code = 'case_created', case = MZPolice.RecordsRepository.getCase(decision.organization.code, publicId) }
  end)
end

function Records.listCases(source, payload)
  if not closed(payload, { kind = true, status = true, page = true, pageSize = true }) then return { ok = false, code = 'invalid_payload' } end
  local decision, authError = authorize(source, MZPoliceConfig.Records.readCapability)
  if not decision then return { ok = false, code = authError } end
  local kind = payload.kind and trim(payload.kind):lower() or nil
  local status = payload.status and trim(payload.status):lower() or nil
  if kind and not CASE_KINDS[kind] then return { ok = false, code = 'invalid_case_kind' } end
  if status and status ~= 'open' and status ~= 'closed' and status ~= 'archived' then return { ok = false, code = 'invalid_case_status' } end
  local page = math.max(1, math.floor(tonumber(payload.page) or 1))
  local limit = math.max(1, math.min(tonumber(MZPoliceConfig.Records.maximumPageSize) or 50,
    math.floor(tonumber(payload.pageSize) or MZPoliceConfig.Records.pageSize or 25)))
  return { ok = true, page = page, pageSize = limit, items = MZPolice.RecordsRepository.listCases(
    decision.organization.code, kind, status, limit, (page - 1) * limit
  ) }
end

function Records.getCase(source, payload)
  if not closed(payload, { caseId = true }) then return { ok = false, code = 'invalid_payload' } end
  local decision, authError = authorize(source, MZPoliceConfig.Records.readCapability)
  if not decision then return { ok = false, code = authError } end
  local case, caseError = getCase(decision, payload.caseId)
  if not case then return { ok = false, code = caseError } end
  audit('case_read', decision, { caseId = case.public_id, result = 'read' })
  return { ok = true, case = case }
end

function Records.updateCase(source, payload)
  if not closed(payload, {
    caseId = true, title = true, summary = true, status = true,
    expectedRevision = true, requestId = true
  }) then return { ok = false, code = 'invalid_payload' } end
  local decision, authError = authorize(source, MZPoliceConfig.Records.writeCapability)
  if not decision then return { ok = false, code = authError } end
  local case, caseError, caseId = getCase(decision, payload.caseId)
  if not case then return { ok = false, code = caseError } end
  local title, summary, status = trim(payload.title), trim(payload.summary), trim(payload.status):lower()
  local expectedRevision = tonumber(payload.expectedRevision)
  if #title < 3 or #title > 160 or #summary > 8000
      or (status ~= 'open' and status ~= 'closed' and status ~= 'archived')
      or not expectedRevision or expectedRevision % 1 ~= 0 or expectedRevision < 1 then
    return { ok = false, code = 'invalid_case_update' }
  end
  local operationId = operation(decision, 'case_update', payload.requestId)
  if not operationId then return { ok = false, code = 'invalid_request_id' } end
  local requestFingerprint = fingerprint(caseId, title, summary, status, expectedRevision)
  return withLock(('case:%s'):format(caseId), function()
    local wasReplayed, replayError = replayed(operationId, requestFingerprint)
    if wasReplayed == nil then return { ok = false, code = replayError } end
    if wasReplayed then
      return { ok = true, code = 'case_updated', case = MZPolice.RecordsRepository.getCase(decision.organization.code, caseId), replayed = true }
    end
    case = MZPolice.RecordsRepository.getCase(decision.organization.code, caseId)
    if tonumber(case.revision) ~= expectedRevision then return { ok = false, code = 'revision_conflict' } end
    local saved = MZPolice.RecordsRepository.updateCase({
      publicId = caseId, orgCode = decision.organization.code, title = title,
      summary = summary, status = status, expectedRevision = expectedRevision,
      history = history(decision, operationId, 'case', caseId, 'case_updated', nil, { status = status }, requestFingerprint)
    })
    if not saved then return { ok = false, code = 'persistence_failed' } end
    audit('case_update', decision, { operationId = operationId, caseId = caseId, status = status, result = 'updated' })
    return { ok = true, code = 'case_updated', case = MZPolice.RecordsRepository.getCase(decision.organization.code, caseId) }
  end)
end

function Records.addCasePerson(source, payload)
  if not closed(payload, { caseId = true, citizenid = true, role = true, requestId = true }) then return { ok = false, code = 'invalid_payload' } end
  local decision, authError = authorize(source, MZPoliceConfig.Records.writeCapability)
  if not decision then return { ok = false, code = authError } end
  local case, caseError, caseId = getCase(decision, payload.caseId)
  if not case then return { ok = false, code = caseError } end
  local character, citizenError, citizenid = citizen(payload.citizenid)
  if not character then return { ok = false, code = citizenError } end
  local role = trim(payload.role):lower()
  if not PERSON_ROLES[role] then return { ok = false, code = 'invalid_person_role' } end
  local operationId = operation(decision, 'person', payload.requestId)
  if not operationId then return { ok = false, code = 'invalid_request_id' } end
  local requestFingerprint = fingerprint(caseId, citizenid, role)
  return withLock(operationId, function()
    local wasReplayed, replayError = replayed(operationId, requestFingerprint)
    if wasReplayed == nil then return { ok = false, code = replayError } end
    if not wasReplayed then
      local saved = MZPolice.RecordsRepository.addCasePerson({
        caseId = caseId, orgCode = decision.organization.code, citizenid = citizenid,
        role = role, actorCitizenid = decision.identity.citizenid,
        history = history(decision, operationId, 'case', caseId, 'person_added', citizenid, { role = role }, requestFingerprint)
      })
      if not saved then return { ok = false, code = 'persistence_failed' } end
    end
    audit('case_person', decision, { operationId = operationId, caseId = caseId, targetCitizenid = citizenid, result = 'updated' })
    return { ok = true, code = 'case_person_updated', case = MZPolice.RecordsRepository.getCase(decision.organization.code, caseId) }
  end)
end

function Records.addCaseCharge(source, payload)
  if not closed(payload, { caseId = true, citizenid = true, ruleCode = true, requestId = true }) then return { ok = false, code = 'invalid_payload' } end
  local decision, authError = authorize(source, MZPoliceConfig.Records.writeCapability)
  if not decision then return { ok = false, code = authError } end
  local case, caseError, caseId = getCase(decision, payload.caseId)
  if not case then return { ok = false, code = caseError } end
  local character, citizenError, citizenid = citizen(payload.citizenid)
  if not character then return { ok = false, code = citizenError } end
  local rule, ruleError = configuredRule('charges', decision.organization.code, payload.ruleCode)
  if not rule then return { ok = false, code = ruleError } end
  if rule.fineAmount < 0 or rule.sentenceSeconds < 0 then return { ok = false, code = 'legal_rule_invalid' } end
  local operationId, requestId = operation(decision, 'charge', payload.requestId)
  if not operationId then return { ok = false, code = 'invalid_request_id' } end
  local publicId = ('charge:%s:%s'):format(decision.identity.citizenid, requestId)
  local requestFingerprint = fingerprint(caseId, citizenid, rule.code, rule.fineAmount, rule.sentenceSeconds)
  return withLock(operationId, function()
    local wasReplayed, replayError = replayed(operationId, requestFingerprint)
    if wasReplayed == nil then return { ok = false, code = replayError } end
    if not wasReplayed then
      local saved = MZPolice.RecordsRepository.addCaseCharge({
        publicId = publicId, caseId = caseId, orgCode = decision.organization.code,
        citizenid = citizenid, ruleCode = rule.code, ruleName = rule.name,
        fineAmount = rule.fineAmount, sentenceSeconds = rule.sentenceSeconds,
        legalVersion = MZPoliceConfig.Records.legalVersion,
        actorCitizenid = decision.identity.citizenid,
        history = history(decision, operationId, 'case', caseId, 'charge_added', citizenid, { ruleCode = rule.code }, requestFingerprint)
      })
      if not saved then return { ok = false, code = 'persistence_failed' } end
    end
    audit('charge_add', decision, { operationId = operationId, caseId = caseId, targetCitizenid = citizenid, ruleCode = rule.code, result = 'created' })
    return { ok = true, code = 'charge_created', chargeId = publicId }
  end)
end

function Records.issueCitation(source, payload)
  if not closed(payload, { caseId = true, citizenid = true, ruleCode = true, requestId = true }) then return { ok = false, code = 'invalid_payload' } end
  local decision, authError = authorize(source, MZPoliceConfig.Records.citationCapability)
  if not decision then return { ok = false, code = authError } end
  local case, caseError, caseId = getCase(decision, payload.caseId)
  if not case then return { ok = false, code = caseError } end
  local character, citizenError, citizenid = citizen(payload.citizenid)
  if not character then return { ok = false, code = citizenError } end
  local rule, ruleError = configuredRule('citations', decision.organization.code, payload.ruleCode)
  if not rule then return { ok = false, code = ruleError } end
  if rule.fineAmount <= 0 then return { ok = false, code = 'legal_rule_invalid' } end
  local operationId, requestId = operation(decision, 'citation', payload.requestId)
  if not operationId then return { ok = false, code = 'invalid_request_id' } end
  local publicId = ('citation:%s:%s'):format(decision.identity.citizenid, requestId)
  local requestFingerprint = fingerprint(caseId, citizenid, rule.code, rule.fineAmount)
  return withLock(operationId, function()
    local citation = MZPolice.RecordsRepository.getCitationByOperation(operationId)
    if citation and (tostring(citation.org_code) ~= decision.organization.code
      or tostring(citation.target_citizenid) ~= citizenid or tostring(citation.case_public_id) ~= caseId
      or tostring(citation.rule_code) ~= rule.code or tonumber(citation.amount) ~= rule.fineAmount) then
      return { ok = false, code = 'request_id_conflict' }
    end
    if not citation then
      local saved = MZPolice.RecordsRepository.createCitation({
        publicId = publicId, operationId = operationId, orgCode = decision.organization.code,
        caseId = caseId, citizenid = citizenid, ruleCode = rule.code, ruleName = rule.name,
        amount = rule.fineAmount, legalVersion = MZPoliceConfig.Records.legalVersion,
        actorCitizenid = decision.identity.citizenid,
        history = history(decision, operationId, 'citation', publicId, 'citation_issued', citizenid, { ruleCode = rule.code }, requestFingerprint)
      })
      if not saved then return { ok = false, code = 'persistence_failed' } end
      citation = MZPolice.RecordsRepository.getCitationByOperation(operationId)
    end
    if tostring(citation.status) == 'paid' then
      return { ok = true, code = 'citation_paid', citation = citation, replayed = true }
    end
    if tostring(citation.status) ~= 'pending' then return { ok = false, code = 'citation_not_payable' } end
    local targetSource, targetError = MZPolice.Bridge.getSourceByCitizenId(citizenid)
    if not targetSource then
      MZPolice.RecordsRepository.finishCitation(publicId, 'pending', nil, targetError)
      return { ok = false, code = targetError, citationId = publicId }
    end
    local organization, orgError = MZPolice.Bridge.getOrganization(decision.organization.code)
    if not organization then return { ok = false, code = orgError } end
    local economyKey = ('fine_%s_%s'):format(tostring(decision.identity.sessionId), requestId)
    if #economyKey > 64 then return { ok = false, code = 'invalid_request_id' } end
    local receipt, settlementError = MZPolice.Bridge.settleCitation(targetSource, organization, rule.fineAmount, {
      idempotencyKey = economyKey, reference = publicId, targetCitizenid = citizenid,
      actorCitizenid = decision.identity.citizenid
    })
    if not receipt then
      MZPolice.RecordsRepository.finishCitation(publicId, 'pending', nil, settlementError)
      audit('citation_issue', decision, { operationId = operationId, caseId = caseId, targetCitizenid = citizenid, ruleCode = rule.code, result = 'pending', reason = settlementError })
      return { ok = false, code = settlementError, citationId = publicId }
    end
    if not MZPolice.RecordsRepository.finishCitation(publicId, 'paid', receipt.receiptId, nil) then
      return { ok = false, code = 'citation_reconciliation_pending', citationId = publicId, receiptId = receipt.receiptId }
    end
    citation = MZPolice.RecordsRepository.getCitationByOperation(operationId)
    audit('citation_issue', decision, { operationId = operationId, caseId = caseId, targetCitizenid = citizenid, ruleCode = rule.code, result = 'paid' })
    return { ok = true, code = 'citation_paid', citation = citation, receipt = receipt }
  end)
end

function Records.createWarrant(source, payload)
  if not closed(payload, { caseId = true, citizenid = true, ruleCode = true, requestId = true }) then return { ok = false, code = 'invalid_payload' } end
  local decision, authError = authorize(source, MZPoliceConfig.Records.warrantCreateCapability)
  if not decision then return { ok = false, code = authError } end
  if type(MZPoliceConfig.Records.warrants) ~= 'table' or MZPoliceConfig.Records.warrants.enabled ~= true then
    return { ok = false, code = 'warrants_disabled' }
  end
  local case, caseError, caseId = getCase(decision, payload.caseId)
  if not case then return { ok = false, code = caseError } end
  local character, citizenError, citizenid = citizen(payload.citizenid)
  if not character then return { ok = false, code = citizenError } end
  local rule, ruleError = configuredRule('warrants', decision.organization.code, payload.ruleCode)
  if not rule then return { ok = false, code = ruleError } end
  local operationId, requestId = operation(decision, 'warrant', payload.requestId)
  if not operationId then return { ok = false, code = 'invalid_request_id' } end
  local publicId = ('warrant:%s:%s'):format(decision.identity.citizenid, requestId)
  local requestFingerprint = fingerprint(caseId, citizenid, rule.code)
  return withLock(operationId, function()
    local wasReplayed, replayError = replayed(operationId, requestFingerprint)
    if wasReplayed == nil then return { ok = false, code = replayError } end
    if not wasReplayed then
      local saved = MZPolice.RecordsRepository.createWarrant({
        publicId = publicId, orgCode = decision.organization.code, caseId = caseId,
        citizenid = citizenid, ruleCode = rule.code, ruleName = rule.name,
        legalVersion = MZPoliceConfig.Records.legalVersion, actorCitizenid = decision.identity.citizenid,
        history = history(decision, operationId, 'warrant', publicId, 'warrant_created', citizenid, { ruleCode = rule.code }, requestFingerprint)
      })
      if not saved then return { ok = false, code = 'persistence_failed' } end
    end
    audit('warrant_create', decision, { operationId = operationId, caseId = caseId, targetCitizenid = citizenid, ruleCode = rule.code, result = 'pending' })
    return { ok = true, code = 'warrant_pending', warrant = MZPolice.RecordsRepository.getWarrant(decision.organization.code, publicId) }
  end)
end

function Records.reviewWarrant(source, payload)
  if not closed(payload, { warrantId = true, action = true, requestId = true }) then return { ok = false, code = 'invalid_payload' } end
  local decision, authError = authorize(source, MZPoliceConfig.Records.warrantApproveCapability)
  if not decision then return { ok = false, code = authError } end
  local publicId = token(payload.warrantId, 8, 160)
  local status = WARRANT_REVIEWS[trim(payload.action):lower()]
  if not publicId or not status then return { ok = false, code = 'invalid_warrant_review' } end
  local warrant = MZPolice.RecordsRepository.getWarrant(decision.organization.code, publicId)
  if not warrant then return { ok = false, code = 'warrant_not_found' } end
  local operationId = operation(decision, 'warrant_review', payload.requestId)
  if not operationId then return { ok = false, code = 'invalid_request_id' } end
  local requestFingerprint = fingerprint(publicId, status)
  return withLock(('warrant:%s'):format(publicId), function()
    local wasReplayed, replayError = replayed(operationId, requestFingerprint)
    if wasReplayed == nil then return { ok = false, code = replayError } end
    if wasReplayed then
      return { ok = true, code = 'warrant_reviewed', warrant = MZPolice.RecordsRepository.getWarrant(decision.organization.code, publicId), replayed = true }
    end
    if tostring(warrant.status) ~= 'pending' then return { ok = false, code = 'warrant_not_pending' } end
    local saved = MZPolice.RecordsRepository.reviewWarrant({
      publicId = publicId, orgCode = decision.organization.code, status = status,
      actorCitizenid = decision.identity.citizenid,
      history = history(decision, operationId, 'warrant', publicId, 'warrant_' .. status, warrant.target_citizenid, nil, requestFingerprint)
    })
    if not saved then return { ok = false, code = 'persistence_failed' } end
    audit('warrant_review', decision, { operationId = operationId, caseId = warrant.case_public_id, targetCitizenid = warrant.target_citizenid, status = status, result = 'reviewed' })
    return { ok = true, code = 'warrant_reviewed', warrant = MZPolice.RecordsRepository.getWarrant(decision.organization.code, publicId) }
  end)
end

function Records.cleanupSource(source) rateLimits[source] = nil end
function Records.stop() rateLimits, locks = {}, {} end

MZPolice.Records = Records
