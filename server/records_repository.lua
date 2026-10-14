MZPolice = MZPolice or {}

local Repository = {}

local function encode(value)
  local ok, result = pcall(json.encode, value or {})
  return ok and result or '{}'
end

local function history(data)
  return {
    query = [[INSERT INTO mz_police_history
      (operation_id, org_code, entity_type, entity_id, action, request_fingerprint,
       actor_citizenid, target_citizenid, details_json)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)]],
    parameters = {
      data.operationId, data.orgCode, data.entityType, data.entityId, data.action,
      data.requestFingerprint, data.actorCitizenid, data.targetCitizenid, encode(data.details)
    }
  }
end

local function transaction(statements, historyData)
  statements[#statements + 1] = history(historyData)
  local ok, value = pcall(MySQL.transaction.await, statements)
  return ok == true and value == true
end

function Repository.getHistoryOperation(operationId)
  return MySQL.single.await('SELECT * FROM mz_police_history WHERE operation_id = ? LIMIT 1', { operationId })
end

function Repository.upsertRecord(data)
  return transaction({ {
    query = [[INSERT INTO mz_police_records (org_code, citizenid, notes, updated_by_citizenid)
      VALUES (?, ?, ?, ?)
      ON DUPLICATE KEY UPDATE notes = VALUES(notes), updated_by_citizenid = VALUES(updated_by_citizenid),
        revision = revision + 1]],
    parameters = { data.orgCode, data.citizenid, data.notes, data.actorCitizenid }
  } }, data.history)
end

function Repository.getRecord(orgCode, citizenid)
  return MySQL.single.await(
    'SELECT * FROM mz_police_records WHERE org_code = ? AND citizenid = ? LIMIT 1',
    { orgCode, citizenid }
  )
end

function Repository.createCase(data)
  return transaction({ {
    query = [[INSERT INTO mz_police_cases
      (public_id, org_code, case_kind, title, summary, status, created_by_citizenid)
      VALUES (?, ?, ?, ?, ?, 'open', ?)]],
    parameters = { data.publicId, data.orgCode, data.kind, data.title, data.summary, data.actorCitizenid }
  }, {
    query = [[INSERT INTO mz_police_case_officers (case_public_id, citizenid, role) VALUES (?, ?, 'creator')]],
    parameters = { data.publicId, data.actorCitizenid }
  } }, data.history)
end

function Repository.getCase(orgCode, publicId)
  local row = MySQL.single.await(
    'SELECT * FROM mz_police_cases WHERE org_code = ? AND public_id = ? LIMIT 1',
    { orgCode, publicId }
  )
  if not row then return nil end
  row.officers = MySQL.query.await(
    'SELECT citizenid, role, created_at FROM mz_police_case_officers WHERE case_public_id = ? ORDER BY created_at ASC',
    { publicId }
  ) or {}
  row.people = MySQL.query.await(
    'SELECT citizenid, role, added_by_citizenid, created_at, updated_at FROM mz_police_case_people WHERE case_public_id = ? ORDER BY created_at ASC',
    { publicId }
  ) or {}
  row.charges = MySQL.query.await(
    'SELECT * FROM mz_police_case_charges WHERE case_public_id = ? ORDER BY created_at ASC', { publicId }
  ) or {}
  return row
end

function Repository.updateCase(data)
  return transaction({ {
    query = [[UPDATE mz_police_cases SET title = ?, summary = ?, status = ?, revision = revision + 1
      WHERE public_id = ? AND org_code = ? AND revision = ?]],
    parameters = {
      data.title, data.summary, data.status, data.publicId, data.orgCode, data.expectedRevision
    }
  } }, data.history)
end

function Repository.listCases(orgCode, kind, status, limit, offset)
  local clauses, params = { 'org_code = ?' }, { orgCode }
  if kind then clauses[#clauses + 1] = 'case_kind = ?'; params[#params + 1] = kind end
  if status then clauses[#clauses + 1] = 'status = ?'; params[#params + 1] = status end
  params[#params + 1], params[#params + 1] = limit, offset
  return MySQL.query.await(([[SELECT public_id, case_kind, title, status, created_by_citizenid,
    revision, created_at, updated_at FROM mz_police_cases WHERE %s
    ORDER BY updated_at DESC LIMIT ? OFFSET ?]]):format(table.concat(clauses, ' AND ')), params) or {}
end

function Repository.addCasePerson(data)
  return transaction({ {
    query = [[INSERT INTO mz_police_case_people
      (case_public_id, citizenid, role, added_by_citizenid) VALUES (?, ?, ?, ?)
      ON DUPLICATE KEY UPDATE role = VALUES(role), added_by_citizenid = VALUES(added_by_citizenid)]],
    parameters = { data.caseId, data.citizenid, data.role, data.actorCitizenid }
  }, {
    query = 'UPDATE mz_police_cases SET revision = revision + 1 WHERE public_id = ? AND org_code = ?',
    parameters = { data.caseId, data.orgCode }
  } }, data.history)
end

function Repository.addCaseCharge(data)
  return transaction({ {
    query = [[INSERT INTO mz_police_case_charges
      (public_id, case_public_id, citizenid, rule_code, rule_name, fine_amount, sentence_seconds,
       legal_version, added_by_citizenid) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)]],
    parameters = {
      data.publicId, data.caseId, data.citizenid, data.ruleCode, data.ruleName,
      data.fineAmount, data.sentenceSeconds, data.legalVersion, data.actorCitizenid
    }
  }, {
    query = 'UPDATE mz_police_cases SET revision = revision + 1 WHERE public_id = ? AND org_code = ?',
    parameters = { data.caseId, data.orgCode }
  } }, data.history)
end

function Repository.getCitationByOperation(operationId)
  return MySQL.single.await('SELECT * FROM mz_police_citations WHERE operation_id = ? LIMIT 1', { operationId })
end

function Repository.createCitation(data)
  return transaction({ {
    query = [[INSERT INTO mz_police_citations
      (public_id, operation_id, org_code, case_public_id, target_citizenid, rule_code, rule_name,
       amount, legal_version, status, issued_by_citizenid)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?)]],
    parameters = {
      data.publicId, data.operationId, data.orgCode, data.caseId, data.citizenid,
      data.ruleCode, data.ruleName, data.amount, data.legalVersion, data.actorCitizenid
    }
  } }, data.history)
end

function Repository.finishCitation(publicId, status, receiptId, errorCode)
  return (MySQL.update.await([[UPDATE mz_police_citations
    SET status = ?, economy_receipt_id = ?, economy_error = ?
    WHERE public_id = ? AND status = 'pending']], { status, receiptId, errorCode, publicId }) or 0) > 0
end

function Repository.createWarrant(data)
  return transaction({ {
    query = [[INSERT INTO mz_police_warrants
      (public_id, org_code, case_public_id, target_citizenid, rule_code, rule_name,
       legal_version, status, created_by_citizenid)
      VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?)]],
    parameters = {
      data.publicId, data.orgCode, data.caseId, data.citizenid, data.ruleCode,
      data.ruleName, data.legalVersion, data.actorCitizenid
    }
  } }, data.history)
end

function Repository.getWarrant(orgCode, publicId)
  return MySQL.single.await(
    'SELECT * FROM mz_police_warrants WHERE org_code = ? AND public_id = ? LIMIT 1',
    { orgCode, publicId }
  )
end

function Repository.reviewWarrant(data)
  return transaction({ {
    query = [[UPDATE mz_police_warrants SET status = ?, reviewed_by_citizenid = ?, reviewed_at = CURRENT_TIMESTAMP
      WHERE public_id = ? AND org_code = ? AND status = 'pending']],
    parameters = { data.status, data.actorCitizenid, data.publicId, data.orgCode }
  } }, data.history)
end

function Repository.getCitizenContext(orgCode, citizenid)
  return {
    record = Repository.getRecord(orgCode, citizenid),
    cases = MySQL.query.await([[SELECT c.public_id, c.case_kind, c.title, c.status, p.role, c.updated_at
      FROM mz_police_case_people p INNER JOIN mz_police_cases c ON c.public_id = p.case_public_id
      WHERE c.org_code = ? AND p.citizenid = ? ORDER BY c.updated_at DESC LIMIT 50]], { orgCode, citizenid }) or {},
    citations = MySQL.query.await([[SELECT public_id, case_public_id, rule_code, rule_name, amount, status,
      economy_receipt_id, created_at FROM mz_police_citations
      WHERE org_code = ? AND target_citizenid = ? ORDER BY created_at DESC LIMIT 50]], { orgCode, citizenid }) or {},
    warrants = MySQL.query.await([[SELECT public_id, case_public_id, rule_code, rule_name, status, created_at,
      reviewed_at FROM mz_police_warrants WHERE org_code = ? AND target_citizenid = ?
      ORDER BY created_at DESC LIMIT 50]], { orgCode, citizenid }) or {},
    history = MySQL.query.await([[SELECT entity_type, entity_id, action, actor_citizenid, details_json, created_at
      FROM mz_police_history WHERE org_code = ? AND target_citizenid = ? ORDER BY id DESC LIMIT 50]],
      { orgCode, citizenid }) or {}
  }
end

MZPolice.RecordsRepository = Repository
