MZPolice = MZPolice or {}

-- Prisao rapida.
--
-- Este modulo e uma camada de ORQUESTRACAO dentro do owner policial. Ele nao
-- cria tabela de caso, writer de sentenca ou sistema de permissao paralelo:
--  - caso/pessoa/charges/historico continuam no owner de records do mz_police;
--  - sentenca continua em mz_prison;
--  - dinheiro continua em mz_economy, sem movimentacao nesta etapa.
--
-- O cliente envia apenas alvo, ruleCodes e observacao. Pena, multa, nome de
-- regra e versao legal sao SEMPRE derivados do catalogo server-side.

local Arrest = {}
local rateLimits, locks = {}, {}

local function trim(value)
  return tostring(value or ''):gsub('%c', ' '):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
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

local function fingerprint(...)
  local hash = 2166136261
  for index = 1, select('#', ...) do
    local value = tostring(select(index, ...) or '')
    for offset = 1, #value do hash = ((hash ~ value:byte(offset)) * 16777619) & 0xffffffff end
    hash = ((hash ~ 31) * 16777619) & 0xffffffff
  end
  return ('%08x'):format(hash)
end

local function rateAllowed(source)
  local settings = type(MZPoliceConfig.Arrest.rateLimit) == 'table' and MZPoliceConfig.Arrest.rateLimit or {}
  local duration = tonumber(settings.windowMs) or 5000
  local maximum = tonumber(settings.maximum) or 8
  local now = type(GetGameTimer) == 'function' and GetGameTimer() or os.time() * 1000
  local window = rateLimits[source]
  if not window or now - window.startedAt >= duration then
    rateLimits[source] = { startedAt = now, count = 1 }
    return true
  end
  window.count = window.count + 1
  return window.count <= maximum
end

local function withLock(key, callback)
  if locks[key] then return { ok = false, code = 'operation_busy' } end
  locks[key] = true
  local packed = table.pack(pcall(callback))
  locks[key] = nil
  if packed[1] ~= true then return { ok = false, code = 'operation_failed' } end
  return table.unpack(packed, 2, packed.n)
end

local function authorize(source)
  if MZPoliceConfig.Arrest.enabled ~= true then return nil, 'arrest_disabled' end
  if not MZPolice.RecordsPrepare or MZPolice.RecordsPrepare.ready ~= true then
    return nil, 'records_unavailable'
  end
  if not rateAllowed(source) then return nil, 'rate_limited' end

  local write = MZPolice.Policy.authorize(source, MZPoliceConfig.Arrest.writeCapability)
  if write.ok ~= true then return nil, write.code end
  local arrest = MZPolice.Policy.authorize(source, MZPoliceConfig.Arrest.capability)
  if arrest.ok ~= true then return nil, arrest.code end
  if tostring(write.organization.code) ~= tostring(arrest.organization.code) then
    return nil, 'organization_mismatch'
  end
  return write
end

local function canCite(source, orgCode)
  local allowed = MZPolice.Bridge.canOrganization(source, orgCode, MZPoliceConfig.Arrest.citationCapability)
  return allowed == true
end

local function coordsFor(source)
  if type(GetPlayerPed) ~= 'function' or type(GetEntityCoords) ~= 'function' then return nil end
  local ped = GetPlayerPed(source)
  if not ped or ped == 0 then return nil end
  local coords = GetEntityCoords(ped)
  if not coords then return nil end
  local x = tonumber(coords.x or coords[1])
  local y = tonumber(coords.y or coords[2])
  local z = tonumber(coords.z or coords[3])
  if not x or not y or not z then return nil end
  return { x = x, y = y, z = z }
end

local function proximity(leftSource, rightSource)
  if type(GetPlayerRoutingBucket) == 'function'
    and tonumber(GetPlayerRoutingBucket(leftSource)) ~= tonumber(GetPlayerRoutingBucket(rightSource)) then
    return false, 'routing_bucket_mismatch'
  end
  local left, right = coordsFor(leftSource), coordsFor(rightSource)
  if not left or not right then return false, 'position_unavailable' end
  local dx, dy, dz = left.x - right.x, left.y - right.y, left.z - right.z
  local maximum = tonumber(MZPoliceConfig.Arrest.maximumDistance)
    or tonumber(MZPoliceConfig.Custody.maximumDistance) or 3.0
  return dx * dx + dy * dy + dz * dz <= maximum * maximum, 'target_too_far'
end

local function displayName(character, citizenid)
  local first = trim(character and (character.firstname or character.firstName) or '')
  local last = trim(character and (character.lastname or character.lastName) or '')
  local name = trim(first .. ' ' .. last)
  return name ~= '' and name or tostring(citizenid or '')
end

local function targetContext(source, targetSource, expectedRevision)
  targetSource = tonumber(targetSource)
  if not targetSource or targetSource <= 0 or targetSource == tonumber(source) then
    return nil, 'invalid_target'
  end
  local custody = MZPolice.Custody.get(targetSource)
  if not custody or custody.cuffed ~= true or not custody.cuffedBy then
    return nil, 'custody_required'
  end
  if tonumber(custody.cuffedBy.source) ~= tonumber(source) then
    return nil, 'custody_required'
  end
  if expectedRevision ~= nil and tonumber(custody.revision) ~= tonumber(expectedRevision) then
    return nil, 'revision_conflict'
  end
  local target = custody.target
  local citizenid = target and token(target.citizenid, 2, 64) or nil
  if not citizenid then return nil, 'invalid_custody_identity' end

  local identity, identityError = MZPolice.Bridge.resolveIdentity(targetSource)
  if not identity or tostring(identity.citizenid) ~= citizenid then
    return nil, identityError or 'identity_inconsistent'
  end
  local death = MZPolice.Bridge.getDeathState(targetSource)
  if not death or tostring(death.deathState or '') ~= 'alive' then
    return nil, 'player_not_alive'
  end
  local close, proximityError = proximity(source, targetSource)
  if not close then return nil, proximityError end

  local character = MZPolice.Bridge.getCharacterByCitizenId(citizenid)
  return {
    source = targetSource,
    citizenid = citizenid,
    name = displayName(character, citizenid),
    character = character,
    identity = identity,
    custody = custody
  }
end

local function requestId(value)
  value = trim(value)
  if #value < 8 or #value > 64 or not value:match('^[%w:_-]+$') then return nil end
  return value
end

local function isActiveSentence(sentence)
  if type(sentence) ~= 'table' or sentence.active == false then return false end
  local status = tostring(sentence.status or '')
  return status == 'intake_pending' or status == 'active' or status == 'release_pending'
end

local function sentenceState(sentence)
  return {
    active = isActiveSentence(sentence),
    status = type(sentence) == 'table' and tostring(sentence.status or '') or 'none',
    remainingSeconds = type(sentence) == 'table' and tonumber(sentence.remaining_seconds or sentence.remainingSeconds) or nil
  }
end

local function maximumCharges()
  local configured = math.max(1, math.floor(tonumber(MZPoliceConfig.Arrest.maximumCharges) or 1))
  if MZPoliceConfig.Arrest.multiChargeEnabled ~= true then return 1 end
  return configured
end

local function arrestMode(value)
  local mode = tostring(value or 'quick'):lower()
  if mode ~= 'quick' and mode ~= 'processing' then return nil end
  if mode == 'quick' and MZPoliceConfig.Arrest.quickEnabled == false then return nil, 'quick_arrest_disabled' end
  return mode
end

local function processingContext(source, targetSource, mode)
  if mode ~= 'processing' then return true end
  local context, contextError = MZPolice.Prison.processingContext(source, targetSource)
  if not context then return nil, contextError end
  return context
end

local function rulesFor(decision, ruleCodes)
  local maximum = maximumCharges()
  if type(ruleCodes) ~= 'table' then return nil, 'invalid_charges' end
  local total = #ruleCodes
  if total < 1 or total > maximum then return nil, 'invalid_charge_count' end

  local catalog, catalogError = MZPolice.Records.legalCatalog(decision)
  if not catalog then return nil, catalogError end
  local byCode = {}
  for _, rule in ipairs(catalog.charges or {}) do byCode[rule.code] = rule end

  local selected, seen = {}, {}
  for _, value in ipairs(ruleCodes) do
    local code = token(value, 2, 64)
    if not code or seen[code] then return nil, 'invalid_charges' end
    seen[code] = true
    local rule = byCode[code]
    if not rule then return nil, 'legal_rule_not_configured' end
    if rule.sentenceSeconds <= 0 then return nil, 'no_custodial_charge' end
    selected[#selected + 1] = rule
  end
  table.sort(selected, function(left, right) return left.code < right.code end)

  local totalSeconds, totalFine = 0, 0
  for _, rule in ipairs(selected) do
    totalSeconds = totalSeconds + rule.sentenceSeconds
    totalFine = totalFine + rule.fineAmount
  end
  if totalSeconds <= 0 then return nil, 'no_custodial_charge' end
  if #selected > 1 then
    local maximumSentence = math.floor(tonumber(MZPoliceConfig.Arrest.maximumSentenceSeconds) or 0)
    if maximumSentence <= 0 then return nil, 'sentence_cap_not_configured' end
    if totalSeconds > maximumSentence then return nil, 'sentence_limit_exceeded' end
  end
  return {
    rules = selected,
    totalSeconds = totalSeconds,
    totalFine = totalFine,
    legalVersion = catalog.legalVersion
  }
end

local function publicTarget(target)
  return {
    citizenid = target.citizenid,
    name = target.name,
    firstname = target.character and (target.character.firstname or target.character.firstName) or nil,
    lastname = target.character and (target.character.lastname or target.character.lastName) or nil
  }
end

local function failure(decision, targetCitizenid, code, fields)
  fields = type(fields) == 'table' and fields or {}
  fields.targetCitizenid = targetCitizenid
  fields.reason = code
  fields.orgCode = decision and decision.organization and decision.organization.code or nil
  if decision and decision.identity then MZPolice.Audit.arrest('failed', decision.identity, fields) end
  return { ok = false, code = code }
end

function Arrest.preview(source, payload)
  if not closed(payload, { targetSource = true, requestId = true, mode = true }) then
    return { ok = false, code = 'invalid_payload' }
  end
  local request = requestId(payload.requestId)
  if not request then return { ok = false, code = 'invalid_request_id' } end
  local mode, modeError = arrestMode(payload.mode)
  if not mode then return { ok = false, code = modeError or 'invalid_arrest_mode' } end

  local decision, authError = authorize(source)
  if not decision then return { ok = false, code = authError } end

  local target, targetError = targetContext(source, payload.targetSource, nil)
  if not target then return failure(decision, nil, targetError) end
  local processing, processingError = processingContext(source, target.source, mode)
  if not processing then return failure(decision, target.citizenid, processingError) end

  local catalog, catalogError = MZPolice.Records.legalCatalog(decision)
  if not catalog then return failure(decision, target.citizenid, catalogError) end

  local charges = {}
  for _, rule in ipairs(catalog.charges or {}) do
    if rule.sentenceSeconds > 0 then
      charges[#charges + 1] = {
        code = rule.code,
        name = rule.name,
        description = tostring(rule.description or ''),
        category = tostring(rule.category or ''),
        fineAmount = rule.fineAmount,
        sentenceSeconds = rule.sentenceSeconds
      }
    end
  end
  if #charges == 0 then return failure(decision, target.citizenid, 'no_custodial_charge') end

  local sentence, sentenceError = MZPolice.Bridge.getSentence(target.citizenid)
  if not sentence then return failure(decision, target.citizenid, sentenceError or 'sentence_read_failed') end
  local currentSentence = sentenceState(sentence)
  if currentSentence.active then
    return failure(decision, target.citizenid, 'active_sentence_exists', { chargeCount = 0 })
  end

  return {
    ok = true,
    code = 'arrest_preview',
    mode = mode,
    target = publicTarget(target),
    catalog = {
      legalVersion = catalog.legalVersion,
      charges = charges
    },
    limits = {
      maxCharges = maximumCharges(),
      minimumReportLength = mode == 'processing'
        and math.max(1, math.floor(tonumber(MZPoliceConfig.Arrest.minimumReportLength) or 1)) or 0,
      maximumNotesLength = math.max(1, math.floor(tonumber(MZPoliceConfig.Arrest.maximumNotesLength) or 4000)),
      maximumSentenceSeconds = math.floor(tonumber(MZPoliceConfig.Arrest.maximumSentenceSeconds) or 0)
    },
    capabilities = { citation = canCite(source, decision.organization.code) },
    custody = { revision = tonumber(target.custody.revision) or 0 },
    sentence = currentSentence,
    processing = type(processing) == 'table' and { pointId = processing.pointId } or nil
  }
end

function Arrest.quote(source, payload)
  if not closed(payload, { targetSource = true, ruleCodes = true, requestId = true, mode = true }) then
    return { ok = false, code = 'invalid_payload' }
  end
  local request = requestId(payload.requestId)
  if not request then return { ok = false, code = 'invalid_request_id' } end
  local mode, modeError = arrestMode(payload.mode)
  if not mode then return { ok = false, code = modeError or 'invalid_arrest_mode' } end

  local decision, authError = authorize(source)
  if not decision then return { ok = false, code = authError } end

  local target, targetError = targetContext(source, payload.targetSource, nil)
  if not target then return failure(decision, nil, targetError) end
  local processing, processingError = processingContext(source, target.source, mode)
  if not processing then return failure(decision, target.citizenid, processingError) end

  local selected, rulesError = rulesFor(decision, payload.ruleCodes)
  if not selected then return failure(decision, target.citizenid, rulesError) end
  if selected.totalFine > 0 and not canCite(source, decision.organization.code) then
    return failure(decision, target.citizenid, 'citation_capability_required')
  end

  return {
    ok = true,
    code = 'arrest_quote',
    mode = mode,
    target = publicTarget(target),
    charges = selected.rules,
    totals = {
      sentenceSeconds = selected.totalSeconds,
      fineAmount = selected.totalFine,
      chargeCount = #selected.rules
    },
    legalVersion = selected.legalVersion,
    capabilities = { citation = canCite(source, decision.organization.code) }
  }
end

function Arrest.commit(source, payload)
  if not closed(payload, {
    targetSource = true, ruleCodes = true, notes = true,
    expectedCustodyRevision = true, requestId = true, mode = true
  }) then
    return { ok = false, code = 'invalid_payload' }
  end
  local request = requestId(payload.requestId)
  if not request then return { ok = false, code = 'invalid_request_id' } end
  local mode, modeError = arrestMode(payload.mode)
  if not mode then return { ok = false, code = modeError or 'invalid_arrest_mode' } end
  local expectedRevision = tonumber(payload.expectedCustodyRevision)
  if not expectedRevision or expectedRevision < 0 or expectedRevision % 1 ~= 0 then
    return { ok = false, code = 'invalid_revision' }
  end
  local notes = trim(payload.notes)
  local maximumNotes = math.max(1, math.floor(tonumber(MZPoliceConfig.Arrest.maximumNotesLength) or 4000))
  if #notes > maximumNotes then return { ok = false, code = 'notes_too_long' } end
  if mode == 'processing'
    and #notes < math.max(1, math.floor(tonumber(MZPoliceConfig.Arrest.minimumReportLength) or 1)) then
    return { ok = false, code = 'report_too_short' }
  end

  local decision, authError = authorize(source)
  if not decision then return { ok = false, code = authError } end

  local target, targetError = targetContext(source, payload.targetSource, expectedRevision)
  if not target then return failure(decision, nil, targetError) end
  local processing, processingError = processingContext(source, target.source, mode)
  if not processing then return failure(decision, target.citizenid, processingError) end

  local selected, rulesError = rulesFor(decision, payload.ruleCodes)
  if not selected then return failure(decision, target.citizenid, rulesError) end
  if selected.totalFine > 0 and not canCite(source, decision.organization.code) then
    return failure(decision, target.citizenid, 'citation_capability_required')
  end

  local sentence, sentenceError = MZPolice.Bridge.getSentence(target.citizenid)
  if not sentence then return failure(decision, target.citizenid, sentenceError or 'sentence_read_failed') end
  if isActiveSentence(sentence) then
    return failure(decision, target.citizenid, 'active_sentence_exists')
  end

  local instanceId = tostring(target.custody.instanceId or '')
  if instanceId == '' then
    instanceId = ('%s:%s:%s'):format(
      tostring(target.identity.sessionId or ''), tostring(target.identity.characterId or ''),
      tostring(target.custody.revision or 0)
    )
  end
  local identityHash = fingerprint(instanceId, target.citizenid)
  local operationId = ('arrest:%s:%s:%s'):format(mode, decision.identity.citizenid, identityHash)
  local caseId = ('case:%s:arrest:%s'):format(decision.identity.citizenid, identityHash)
  local codes = {}
  for _, rule in ipairs(selected.rules) do codes[#codes + 1] = rule.code end
  table.sort(codes)
  local requestFingerprint = fingerprint(
    instanceId, target.citizenid, table.concat(codes, ','), notes,
    tostring(expectedRevision), selected.legalVersion,
    tostring(selected.totalSeconds), tostring(selected.totalFine), mode
  )

  return withLock('citizen:' .. target.citizenid, function()
    local currentCustody = MZPolice.Custody.get(target.source)
    if not currentCustody or currentCustody.cuffed ~= true or not currentCustody.cuffedBy
      or tonumber(currentCustody.cuffedBy.source) ~= tonumber(source)
      or tonumber(currentCustody.revision) ~= expectedRevision
      or tostring(currentCustody.instanceId or '') ~= instanceId then
      return failure(decision, target.citizenid, 'custody_required')
    end
    local currentSentence = MZPolice.Bridge.getSentence(target.citizenid)
    if not currentSentence then
      return failure(decision, target.citizenid, 'sentence_read_failed')
    end
    if isActiveSentence(currentSentence) then
      return failure(decision, target.citizenid, 'active_sentence_exists')
    end
    local currentProcessing, currentProcessingError = processingContext(source, target.source, mode)
    if not currentProcessing then return failure(decision, target.citizenid, currentProcessingError) end

    local existing = MZPolice.RecordsRepository.getHistoryOperation(operationId)
    if existing then
      if tostring(existing.request_fingerprint or existing.requestFingerprint or '') ~= requestFingerprint then
        return failure(decision, target.citizenid, 'request_id_conflict', { caseId = caseId })
      end
      local case = MZPolice.RecordsRepository.getCase(decision.organization.code, caseId)
      if not case then return failure(decision, target.citizenid, 'persistence_failed', { caseId = caseId }) end
      local chargeIds, charges, citationCharges = {}, {}, {}
      local replaySeconds, replayFine = 0, 0
      for _, charge in ipairs(case.charges or {}) do
        local chargeId = tostring(charge.public_id)
        chargeIds[#chargeIds + 1] = chargeId
        local chargeSeconds = tonumber(charge.sentence_seconds) or 0
        local chargeFine = tonumber(charge.fine_amount) or 0
        replaySeconds = replaySeconds + chargeSeconds
        replayFine = replayFine + chargeFine
        charges[#charges + 1] = {
          chargeId = chargeId, ruleCode = tostring(charge.rule_code),
          ruleName = tostring(charge.rule_name), sentenceSeconds = chargeSeconds,
          fineAmount = chargeFine, legalVersion = tostring(charge.legal_version)
        }
        citationCharges[#citationCharges + 1] = {
          publicId = chargeId, citizenid = tostring(charge.citizenid),
          ruleCode = tostring(charge.rule_code), ruleName = tostring(charge.rule_name),
          fineAmount = tonumber(charge.fine_amount) or 0,
          sentenceSeconds = tonumber(charge.sentence_seconds) or 0,
          legalVersion = tostring(charge.legal_version)
        }
      end
      local citations, citationError = MZPolice.Records.issueArrestCitations(decision, caseId, citationCharges)
      local warnings = {}
      if replayFine > 0 and (not citations or #citations == 0) then
        warnings[#warnings + 1] = tostring(citationError or 'citation_issue_failed')
      end
      return {
        ok = true, code = mode == 'processing' and 'processing_arrest_replayed' or 'quick_arrest_replayed',
        mode = mode, replayed = true,
        caseId = caseId, chargeId = chargeIds[1], chargeIds = chargeIds, charges = charges,
        targetSource = target.source,
        target = publicTarget(target),
        totals = { sentenceSeconds = replaySeconds, fineAmount = replayFine, chargeCount = #charges },
        legalVersion = selected.legalVersion,
        citations = citations or {},
        warnings = warnings
      }
    end

    if MZPolice.RecordsRepository.getCase(decision.organization.code, caseId) then
      return failure(decision, target.citizenid, 'persistence_failed', { caseId = caseId })
    end

    local charges = {}
    for index, rule in ipairs(selected.rules) do
      charges[#charges + 1] = {
        publicId = ('charge:%s'):format(fingerprint(caseId, rule.code, tostring(index))),
        citizenid = target.citizenid,
        ruleCode = rule.code,
        ruleName = rule.name,
        fineAmount = rule.fineAmount,
        sentenceSeconds = rule.sentenceSeconds,
        legalVersion = selected.legalVersion
      }
    end

    local title = ((mode == 'processing' and 'Processamento prisional — ' or 'Prisão rápida — ') .. target.name)
    if #title > 160 then title = title:sub(1, 160) end
    local saved = MZPolice.RecordsRepository.createQuickArrest({
      publicId = caseId,
      orgCode = decision.organization.code,
      kind = 'occurrence',
      title = title,
      summary = notes,
      actorCitizenid = decision.identity.citizenid,
      personCitizenid = target.citizenid,
      charges = charges,
      history = {
        operationId = operationId,
        orgCode = decision.organization.code,
        entityType = 'case',
        entityId = caseId,
        action = mode == 'processing' and 'processing_arrest_created' or 'quick_arrest_created',
        requestFingerprint = requestFingerprint,
        actorCitizenid = decision.identity.citizenid,
        targetCitizenid = target.citizenid,
        details = {
          chargeIds = (function()
            local ids = {}
            for _, charge in ipairs(charges) do ids[#ids + 1] = charge.publicId end
            return ids
          end)(),
          ruleCodes = codes,
          sentenceSeconds = selected.totalSeconds,
          fineAmount = selected.totalFine,
          legalVersion = selected.legalVersion,
          custodyRevision = expectedRevision,
          mode = mode,
          processingPointId = type(currentProcessing) == 'table' and currentProcessing.pointId or nil
        }
      }
    })
    if not saved then return failure(decision, target.citizenid, 'persistence_failed', { caseId = caseId }) end

    -- A multa nasce DEPOIS do caso/charges confirmados e permanece pendente.
    -- Nao existe debito automatico na prisao.
    local citations, citationError = MZPolice.Records.issueArrestCitations(decision, caseId, charges)
    local warnings = {}
    if selected.totalFine > 0 and (not citations or #citations == 0) then
      warnings[#warnings + 1] = tostring(citationError or 'citation_issue_failed')
      MZPolice.Audit.arrest('citation_failed', decision.identity, {
        targetCitizenid = target.citizenid,
        orgCode = decision.organization.code,
        caseId = caseId,
        operationId = operationId,
        result = 'pending',
        reason = citationError
      })
    end

    local chargeIds = {}
    for _, charge in ipairs(charges) do chargeIds[#chargeIds + 1] = charge.publicId end
    MZPolice.Audit.arrest('committed', decision.identity, {
      targetCitizenid = target.citizenid,
      orgCode = decision.organization.code,
      caseId = caseId,
      operationId = operationId,
      custodyRevision = expectedRevision,
      ruleCodes = table.concat(codes, ','),
      sentenceSeconds = selected.totalSeconds,
      fineAmount = selected.totalFine,
      legalVersion = selected.legalVersion,
      chargeCount = #charges,
      result = 'created'
    })

    return {
      ok = true, code = mode == 'processing' and 'processing_arrest_created' or 'quick_arrest_created',
      mode = mode, replayed = false,
      caseId = caseId, chargeId = chargeIds[1], chargeIds = chargeIds, charges = charges,
      targetSource = target.source,
      target = publicTarget(target),
      totals = {
        sentenceSeconds = selected.totalSeconds,
        fineAmount = selected.totalFine,
        chargeCount = #charges
      },
      legalVersion = selected.legalVersion,
      citations = citations or {},
      warnings = warnings
    }
  end)
end

function Arrest.cleanupSource(source)
  source = tonumber(source)
  if source then rateLimits[source] = nil end
end

function Arrest.stop()
  rateLimits, locks = {}, {}
end

MZPolice.Arrest = Arrest
