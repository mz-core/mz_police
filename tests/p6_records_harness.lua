local function expect(condition, message) if not condition then error(message, 2) end end

local now, caseCreates, citationCreates, settlements, audits = 1000, 0, 0, 0, 0
local histories, cases, citations, warrants = {}, {}, {}, {}
function GetGameTimer() now = now + 1; return now end

MZPoliceConfig = { Records = {
  readCapability = 'mdt.open', writeCapability = 'police.records.write',
  citationCapability = 'police.citation.issue', warrantCreateCapability = 'police.warrant.create',
  warrantApproveCapability = 'police.warrant.approve', pageSize = 25, maximumPageSize = 50,
  rateLimit = { maximum = 50, windowMs = 5000 }, legalRulesEnabled = false,
  legalVersion = 'test-v1', jurisdictions = { police = { enabled = true } },
  charges = { theft = { enabled = true, name = 'Theft', fineAmount = 100, sentenceSeconds = 60 } },
  citations = { speeding = { enabled = true, name = 'Speeding', fineAmount = 100 } },
  warrants = { enabled = true, rules = { arrest = { enabled = true, name = 'Arrest' } } }
} }

MZPolice = {
  RecordsPrepare = { ready = true },
  Policy = { authorize = function(source, capability)
    if source ~= 1 then return { ok = false, code = 'capability_denied' } end
    return {
      ok = true, capability = capability,
      identity = { citizenid = 'OFFICER1', sessionId = 77 },
      organization = { code = 'police' }
    }
  end },
  Bridge = {
    searchCharacters = function() return { items = { { citizenid = 'TARGET1' } }, total = 1 } end,
    getCharacterByCitizenId = function(value)
      if value == 'MISSING' then return nil, 'citizen_not_found' end
      return { citizenid = value, firstname = 'Target', lastname = 'Person' }
    end,
    getSourceByCitizenId = function() return 2 end,
    getOrganization = function() return { id = 1, code = 'police', active = true, hasSharedAccount = true } end,
    settleCitation = function(_, _, amount)
      settlements = settlements + 1
      return { receiptId = 'receipt-1', amount = amount }
    end
  },
  Audit = { records = function() audits = audits + 1 end }
}

MZPolice.RecordsRepository = {
  getHistoryOperation = function(id) return histories[id] end,
  createCase = function(data)
    caseCreates = caseCreates + 1
    cases[data.publicId] = {
      public_id = data.publicId, org_code = data.orgCode, case_kind = data.kind,
      title = data.title, summary = data.summary, status = 'open'
      , revision = 1
    }
    histories[data.history.operationId] = data.history
    return true
  end,
  getCase = function(orgCode, id)
    local value = cases[id]
    return value and value.org_code == orgCode and value or nil
  end,
  listCases = function() return {} end,
  updateCase = function(data)
    local value = cases[data.publicId]
    value.title, value.summary, value.status, value.revision = data.title, data.summary, data.status, value.revision + 1
    histories[data.history.operationId] = data.history
    return true
  end,
  upsertRecord = function(data) histories[data.history.operationId] = data.history; return true end,
  getRecord = function(orgCode, citizenid) return { org_code = orgCode, citizenid = citizenid, revision = 1 } end,
  getCitizenContext = function() return { cases = {}, citations = {}, warrants = {}, history = {} } end,
  addCasePerson = function(data) histories[data.history.operationId] = data.history; return true end,
  addCaseCharge = function(data) histories[data.history.operationId] = data.history; return true end,
  getCitationByOperation = function(id) return citations[id] end,
  createCitation = function(data)
    citationCreates = citationCreates + 1
    citations[data.operationId] = {
      public_id = data.publicId, operation_id = data.operationId, org_code = data.orgCode,
      case_public_id = data.caseId, target_citizenid = data.citizenid,
      rule_code = data.ruleCode, amount = data.amount, status = 'pending'
    }
    histories[data.history.operationId] = data.history
    return true
  end,
  finishCitation = function(id, status, receipt, errorCode)
    for _, value in pairs(citations) do
      if value.public_id == id then
        value.status, value.economy_receipt_id, value.economy_error = status, receipt, errorCode
        return true
      end
    end
    return false
  end,
  createWarrant = function(data)
    warrants[data.publicId] = {
      public_id = data.publicId, org_code = data.orgCode, case_public_id = data.caseId,
      target_citizenid = data.citizenid, status = 'pending'
    }
    histories[data.history.operationId] = data.history
    return true
  end,
  getWarrant = function(orgCode, id)
    local value = warrants[id]
    return value and value.org_code == orgCode and value or nil
  end,
  reviewWarrant = function(data)
    warrants[data.publicId].status = data.status
    histories[data.history.operationId] = data.history
    return true
  end
}

dofile('server/records.lua')

local search = MZPolice.Records.searchCitizens(1, { query = 'Ta', page = 1, pageSize = 10 })
expect(search.ok == true and search.result.total == 1, 'busca autorizada falhou')
expect(MZPolice.Records.searchCitizens(2, { query = 'Ta' }).code == 'capability_denied', 'busca sem autorizacao foi aceita')
expect(MZPolice.Records.searchCitizens(1, { query = 'Ta', forged = true }).code == 'invalid_payload', 'payload aberto foi aceito')

local created = MZPolice.Records.createCase(1, {
  kind = 'occurrence', title = 'Occurrence A', summary = 'Summary', requestId = 'request_case_001'
})
expect(created.ok == true and caseCreates == 1, 'criacao de caso falhou')
local replay = MZPolice.Records.createCase(1, {
  kind = 'occurrence', title = 'Occurrence A', summary = 'Summary', requestId = 'request_case_001'
})
expect(replay.ok == true and caseCreates == 1, 'replay duplicou caso')
local conflictingReplay = MZPolice.Records.createCase(1, {
  kind = 'occurrence', title = 'Different payload', summary = 'Summary', requestId = 'request_case_001'
})
expect(conflictingReplay.ok == false and conflictingReplay.code == 'request_id_conflict', 'requestId conflitante foi aceito')
local updated = MZPolice.Records.updateCase(1, {
  caseId = created.case.public_id, title = 'Occurrence updated', summary = 'Summary 2',
  status = 'closed', expectedRevision = 1, requestId = 'request_case_update_001'
})
expect(updated.ok == true and updated.case.status == 'closed' and updated.case.revision == 2, 'atualizacao de caso falhou')
local stale = MZPolice.Records.updateCase(1, {
  caseId = created.case.public_id, title = 'Stale update', summary = '',
  status = 'open', expectedRevision = 1, requestId = 'request_case_update_002'
})
expect(stale.ok == false and stale.code == 'revision_conflict', 'revisao obsoleta foi aceita')

local disabled = MZPolice.Records.issueCitation(1, {
  caseId = created.case.public_id, citizenid = 'TARGET1', ruleCode = 'speeding', requestId = 'request_fine_001'
})
expect(disabled.ok == false and disabled.code == 'legal_rules_disabled', 'regra legal desabilitada foi usada')

MZPoliceConfig.Records.legalRulesEnabled = true
local paid = MZPolice.Records.issueCitation(1, {
  caseId = created.case.public_id, citizenid = 'TARGET1', ruleCode = 'speeding', requestId = 'request_fine_001'
})
expect(paid.ok == true and paid.code == 'citation_paid' and settlements == 1 and citationCreates == 1, 'multa nao foi liquidada')
local paidReplay = MZPolice.Records.issueCitation(1, {
  caseId = created.case.public_id, citizenid = 'TARGET1', ruleCode = 'speeding', requestId = 'request_fine_001'
})
expect(paidReplay.ok == true and paidReplay.replayed == true and settlements == 1, 'replay cobrou multa novamente')

local warrant = MZPolice.Records.createWarrant(1, {
  caseId = created.case.public_id, citizenid = 'TARGET1', ruleCode = 'arrest', requestId = 'request_warrant_001'
})
expect(warrant.ok == true and warrant.warrant.status == 'pending', 'mandado pendente nao foi criado')
local reviewed = MZPolice.Records.reviewWarrant(1, {
  warrantId = warrant.warrant.public_id, action = 'approve', requestId = 'request_review_001'
})
expect(reviewed.ok == true and reviewed.warrant.status == 'approved', 'mandado nao foi aprovado')
expect(audits >= 5, 'auditoria central nao foi chamada')

print('mz_police P6 records harness: PASS cases=13')
