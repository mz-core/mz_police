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
    description = trim(rule.description):sub(1, 400),
    category = trim(rule.category):sub(1, 64),
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

local function nearby(leftSource, rightSource)
  if type(GetPlayerRoutingBucket) == 'function'
    and tonumber(GetPlayerRoutingBucket(leftSource)) ~= tonumber(GetPlayerRoutingBucket(rightSource)) then
    return false, 'routing_bucket_mismatch'
  end
  if type(GetPlayerPed) ~= 'function' or type(GetEntityCoords) ~= 'function' then
    return false, 'position_unavailable'
  end
  local leftPed, rightPed = GetPlayerPed(leftSource), GetPlayerPed(rightSource)
  local left = leftPed and leftPed > 0 and GetEntityCoords(leftPed) or nil
  local right = rightPed and rightPed > 0 and GetEntityCoords(rightPed) or nil
  local lx, ly, lz = left and tonumber(left.x), left and tonumber(left.y), left and tonumber(left.z)
  local rx, ry, rz = right and tonumber(right.x), right and tonumber(right.y), right and tonumber(right.z)
  if not lx or not ly or not lz or not rx or not ry or not rz then return false, 'position_unavailable' end
  local maximum = tonumber(MZPoliceConfig.Custody.maximumDistance) or 2.5
  return (lx - rx) ^ 2 + (ly - ry) ^ 2 + (lz - rz) ^ 2 <= maximum ^ 2, 'target_too_far'
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

function Records.lookupVehicle(source, payload)
  if not closed(payload, { plate = true }) then return { ok = false, code = 'invalid_payload' } end
  local decision, authError = authorize(source, MZPoliceConfig.Records.readCapability)
  if not decision then return { ok = false, code = authError } end
  local plate = trim(payload.plate):upper():gsub('%s+', '')
  if #plate < 2 or #plate > 16 or not plate:match('^[A-Z0-9-]+$') then
    return { ok = false, code = 'invalid_vehicle_plate' }
  end
  local vehicle, vehicleError = MZPolice.Bridge.getVehicleByPlate(plate)
  if not vehicle then
    audit('vehicle_lookup', decision, { result = 'denied', reason = vehicleError })
    return { ok = false, code = vehicleError }
  end
  local owner
  if tostring(vehicle.owner_type or '') == 'player' and tostring(vehicle.owner_id or '') ~= '' then
    owner = MZPolice.Bridge.getCharacterByCitizenId(tostring(vehicle.owner_id))
  end
  local flags = {}
  local policeFlags = type(vehicle.metadata_json) == 'table' and vehicle.metadata_json.policeFlags or nil
  for code, entry in pairs(type(policeFlags) == 'table' and policeFlags or {}) do
    if type(entry) == 'table' and entry.active == true then
      flags[#flags + 1] = { code = tostring(code):sub(1, 48), reference = tostring(entry.reference or ''):sub(1, 96) }
    end
  end
  table.sort(flags, function(left, right) return left.code < right.code end)
  audit('vehicle_lookup', decision, { entityId = tostring(vehicle.id or ''), result = 'read' })
  return {
    ok = true,
    vehicle = {
      plate = tostring(vehicle.plate or plate), model = tostring(vehicle.model or ''),
      state = tostring(vehicle.state or ''), garage = tostring(vehicle.garage or ''),
      ownerType = tostring(vehicle.owner_type or ''), ownerId = tostring(vehicle.owner_id or ''),
      impounded = tostring(vehicle.state or '') == 'impounded', flags = flags,
      owner = type(owner) == 'table' and {
        citizenid = tostring(owner.citizenid or ''), firstname = tostring(owner.firstname or owner.firstName or ''),
        lastname = tostring(owner.lastname or owner.lastName or '')
      } or nil
    }
  }
end

-- Catalogo derivado de uma decisao de policy ja autorizada. Uso interno do
-- owner policial (MDT e prisao rapida) para nao repetir policy/rate-limit.
function Records.legalCatalog(decision)
  if type(decision) ~= 'table' or type(decision.organization) ~= 'table'
    or type(decision.organization.code) ~= 'string' then
    return nil, 'invalid_decision'
  end
  local config = MZPoliceConfig.Records
  if config.legalRulesEnabled ~= true then return nil, 'legal_rules_disabled' end
  local jurisdiction = type(config.jurisdictions) == 'table'
    and config.jurisdictions[decision.organization.code] or nil
  if type(jurisdiction) ~= 'table' or jurisdiction.enabled ~= true then
    return nil, 'jurisdiction_disabled'
  end

  local charges = {}
  for code in pairs(type(config.charges) == 'table' and config.charges or {}) do
    local rule = configuredRule('charges', decision.organization.code, code)
    if rule and rule.fineAmount >= 0 and rule.sentenceSeconds >= 0 then charges[#charges + 1] = rule end
  end
  table.sort(charges, function(left, right) return left.code < right.code end)
  return {
    legalVersion = config.legalVersion,
    organization = decision.organization.code,
    charges = charges
  }
end

function Records.getChargeRule(orgCode, ruleCode)
  return configuredRule('charges', orgCode, ruleCode)
end

function Records.getLegalCatalog(source, payload)
  if not closed(payload, {}) then return { ok = false, code = 'invalid_payload' } end
  local decision, authError = authorize(source, MZPoliceConfig.Records.writeCapability)
  if not decision then return { ok = false, code = authError } end
  local catalog, catalogError = Records.legalCatalog(decision)
  if not catalog then return { ok = false, code = catalogError } end
  return {
    ok = true,
    code = 'legal_catalog_loaded',
    legalVersion = catalog.legalVersion,
    organization = catalog.organization,
    charges = catalog.charges
  }
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

-- Multas de prisao.
-- Cria SOMENTE citations pendentes, depois que o caso/charges ja foram
-- confirmados. Nao chama mz_economy e nao debita nada automaticamente.
function Records.issueArrestCitations(decision, caseId, charges)
  if type(decision) ~= 'table' or type(decision.identity) ~= 'table'
    or type(decision.organization) ~= 'table' then return nil, 'invalid_decision' end
  local citationAllowed = MZPolice.Bridge.canOrganization(
    decision.source, decision.organization.code, MZPoliceConfig.Records.citationCapability
  )
  if citationAllowed ~= true then return nil, 'citation_capability_required' end
  caseId = token(caseId, 8, 160)
  if not caseId then return nil, 'invalid_case_id' end
  local created = {}
  for _, charge in ipairs(charges or {}) do
    local amount = math.floor(tonumber(charge.fineAmount) or 0)
    local chargeId = token(charge.publicId, 8, 160)
    local targetCitizenid = token(charge.citizenid, 2, 64)
    local ruleCode = token(charge.ruleCode, 2, 64)
    local ruleName = trim(charge.ruleName)
    local legalVersion = trim(charge.legalVersion)
    if amount > 0 then
      if not chargeId or not targetCitizenid or not ruleCode or ruleName == '' or legalVersion == '' then
        return nil, 'invalid_charge'
      end
      local publicId = 'citation:' .. chargeId
      local operationId = 'charge_fine:' .. chargeId
      local citation = MZPolice.RecordsRepository.getCitationByOperation(operationId)
      if citation then
        if tostring(citation.public_id) ~= publicId
          or tostring(citation.case_public_id) ~= caseId
          or tostring(citation.target_citizenid) ~= targetCitizenid
          or tonumber(citation.amount) ~= amount
          or tostring(citation.rule_code) ~= ruleCode then
          return nil, 'request_id_conflict'
        end
      else
        local requestFingerprint = fingerprint(caseId, chargeId, amount, ruleCode, legalVersion)
        local saved = MZPolice.RecordsRepository.createCitation({
          publicId = publicId, operationId = operationId, orgCode = decision.organization.code,
          caseId = caseId, citizenid = targetCitizenid, ruleCode = ruleCode, ruleName = ruleName,
          amount = amount, legalVersion = legalVersion, actorCitizenid = decision.identity.citizenid,
          history = history(decision, operationId, 'citation', publicId, 'arrest_citation_created',
            targetCitizenid, { chargeId = chargeId, caseId = caseId, amount = amount }, requestFingerprint)
        })
        if not saved then return nil, 'persistence_failed' end
        citation = MZPolice.RecordsRepository.getCitationByOperation(operationId)
      end
      if citation then created[#created + 1] = citation end
    end
  end
  return created
end

-- Pagamento de citation pelo proprio cidadao. O debito acontece somente por
-- este contrato, com idempotencia do mz_economy. Nao ha debito na prisao.
function Records.payCitation(source, payload)
  if not closed(payload, { citationId = true, requestId = true }) then
    return { ok = false, code = 'invalid_payload' }
  end
  if not MZPolice.RecordsPrepare.ready then return { ok = false, code = 'records_unavailable' } end
  if not rateAllowed(source) then return { ok = false, code = 'rate_limited' } end
  local citationId = token(payload.citationId, 8, 160)
  local request = token(payload.requestId, 8, 40)
  if not citationId or not request then return { ok = false, code = 'invalid_request' } end
  local identity, identityError = MZPolice.Bridge.resolveIdentity(source)
  if not identity then return { ok = false, code = identityError } end
  local citation = MZPolice.RecordsRepository.getCitationByPublicId(citationId)
  if not citation or tostring(citation.target_citizenid) ~= tostring(identity.citizenid) then
    return { ok = false, code = 'citation_not_found' }
  end
  if tostring(citation.status) == 'paid' then
    return { ok = true, code = 'citation_paid', citation = citation, replayed = true }
  end
  if tostring(citation.status) ~= 'pending' then return { ok = false, code = 'citation_not_payable' } end
  local amount = math.floor(tonumber(citation.amount) or 0)
  if amount <= 0 then return { ok = false, code = 'invalid_amount' } end
  local organization, orgError = MZPolice.Bridge.getOrganization(citation.org_code)
  if not organization then return { ok = false, code = orgError } end
  local idempotencyKey = 'charge_fine_' .. fingerprint(citation.public_id)
  if #idempotencyKey > 64 then return { ok = false, code = 'invalid_request_id' } end
  local receipt, settlementError = MZPolice.Bridge.settleCitation(source, organization, amount, {
    idempotencyKey = idempotencyKey, reference = citation.public_id,
    targetCitizenid = identity.citizenid, actorCitizenid = identity.citizenid
  })
  if not receipt then
    MZPolice.RecordsRepository.finishCitation(citation.public_id, 'pending', nil, settlementError)
    return { ok = false, code = settlementError, citationId = citation.public_id }
  end
  if not MZPolice.RecordsRepository.finishCitation(citation.public_id, 'paid', receipt.receiptId, nil) then
    return { ok = false, code = 'citation_reconciliation_pending', citationId = citation.public_id, receiptId = receipt.receiptId }
  end
  citation = MZPolice.RecordsRepository.getCitationByPublicId(citation.public_id)
  if not citation then return { ok = false, code = 'persistence_failed', citationId = citationId } end
  MZPolice.Audit.records('citation_paid', {
    identity = identity, organization = { code = citation.org_code }
  }, {
    orgCode = citation.org_code, targetCitizenid = identity.citizenid,
    result = 'paid', status = 'paid'
  })
  return { ok = true, code = 'citation_paid', citation = citation, receipt = receipt }
end

function Records.requestCitationPayment(source, payload)
  if not closed(payload, { targetSource = true, citationId = true, requestId = true }) then
    return { ok = false, code = 'invalid_payload' }
  end
  local decision, authError = authorize(source, MZPoliceConfig.Records.citationCapability)
  if not decision then return { ok = false, code = authError } end
  local targetSource = tonumber(payload.targetSource)
  local citationId = token(payload.citationId, 8, 160)
  local request = token(payload.requestId, 8, 40)
  if not targetSource or targetSource <= 0 or targetSource == tonumber(source)
    or not citationId or not request then return { ok = false, code = 'invalid_request' } end
  local target, targetError = MZPolice.Bridge.resolveIdentity(targetSource)
  if not target then return { ok = false, code = targetError } end
  local close, proximityError = nearby(source, targetSource)
  if not close then return { ok = false, code = proximityError } end
  local citation = MZPolice.RecordsRepository.getCitationByPublicId(citationId)
  if not citation or tostring(citation.target_citizenid) ~= tostring(target.citizenid)
    or tostring(citation.org_code) ~= tostring(decision.organization.code) then
    return { ok = false, code = 'citation_not_found' }
  end
  if tostring(citation.status) ~= 'pending' then return { ok = false, code = 'citation_not_payable' } end
  local amount = math.floor(tonumber(citation.amount) or 0)
  if amount <= 0 then return { ok = false, code = 'invalid_amount' } end
  TriggerClientEvent('mz_police:client:citations:paymentRequest', targetSource, {
    citationId = citationId, amount = amount, ruleName = tostring(citation.rule_name or ''),
    requestedBy = decision.identity.citizenid
  })
  audit('citation_payment_requested', decision, {
    targetCitizenid = target.citizenid, result = 'requested', status = 'pending'
  })
  return { ok = true, code = 'citation_payment_requested', citationId = citationId }
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
