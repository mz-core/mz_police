local function expect(condition, message) if not condition then error(message, 2) end end
local now, listFailure, auditCount = 1000, nil, 0
local linked, history = {}, {}
function GetGameTimer() now = now + 1; return now end

MZPoliceConfig = { Evidence = {
  listCapability = 'police.evidence.collect', manageCapability = 'police.evidence.manage',
  requestRetentionMs = 120000, rateLimit = { maximum = 50, windowMs = 5000 },
  occurrenceAssociationEnabled = false,
  containers = { intake = { label = 'Intake', enabled = true } }
} }

local function caseRow()
  local evidence = {}
  for _, row in pairs(linked) do evidence[#evidence + 1] = row end
  return { public_id = 'case:0001', org_code = 'police', evidence = evidence }
end

MZPolice = {
  RecordsPrepare = { ready = true },
  Policy = { authorize = function(source)
    if source ~= 1 then return { ok = false, code = 'capability_denied' } end
    return {
      ok = true, identity = { sessionId = 55, citizenid = 'POLICE1' },
      organization = { code = 'police' }
    }
  end },
  Bridge = { listPoliceEvidence = function()
    if listFailure then return nil, listFailure end
    return { {
      instanceUid = 'evidence-uid', item = 'evidence', label = 'Evidence bag', amount = 1,
      evidence = { evidenceId = 'evidence:evidence-uid', orgCode = 'police', containerId = 'intake', revision = 2 }
    } }
  end },
  RecordsRepository = {
    getCase = function(_, caseId) return caseId == 'case:0001' and caseRow() or nil end,
    getHistoryOperation = function(operationId) return history[operationId] end,
    getCaseEvidence = function(caseId, evidenceId) return linked[caseId .. ':' .. evidenceId] end,
    linkCaseEvidence = function(data)
      linked[data.caseId .. ':' .. data.evidenceId] = {
        evidence_id = data.evidenceId, instance_uid = data.instanceUid,
        linked_by_citizenid = data.actorCitizenid, linked_evidence_revision = data.evidenceRevision
      }
      history[data.history.operationId] = { request_fingerprint = data.history.requestFingerprint }
      return true
    end
  },
  Audit = { evidence = function() auditCount = auditCount + 1 end }
}

dofile('server/evidence.lua')

local disabled = MZPolice.Evidence.linkCase(1, {
  caseId = 'case:0001', containerId = 'intake', instanceUid = 'evidence-uid', requestId = 'link-request-001'
})
expect(disabled.ok == false and disabled.code == 'evidence_association_disabled', 'flag desativada foi ignorada')

MZPoliceConfig.Evidence.occurrenceAssociationEnabled = true
local arbitrary = MZPolice.Evidence.linkCase(1, {
  caseId = 'case:0001', containerId = 'intake', instanceUid = 'invented-uid', requestId = 'link-request-002'
})
expect(arbitrary.ok == false and arbitrary.code == 'evidence_not_found', 'evidencia arbitraria foi aceita')

local denied = MZPolice.Evidence.linkCase(2, {
  caseId = 'case:0001', containerId = 'intake', instanceUid = 'evidence-uid', requestId = 'link-request-003'
})
expect(denied.ok == false and denied.code == 'capability_denied', 'autorizacao ausente foi aceita')

listFailure = 'mz_inventory_unavailable'
local dependency = MZPolice.Evidence.linkCase(1, {
  caseId = 'case:0001', containerId = 'intake', instanceUid = 'evidence-uid', requestId = 'link-request-004'
})
expect(dependency.ok == false and dependency.code == 'mz_inventory_unavailable', 'falha da dependencia foi ocultada')
listFailure = nil

local created = MZPolice.Evidence.linkCase(1, {
  caseId = 'case:0001', containerId = 'intake', instanceUid = 'evidence-uid', requestId = 'link-request-005'
})
expect(created.ok == true and #created.case.evidence == 1 and auditCount == 1, 'vinculo autorizado falhou')

MZPolice.Evidence.stop()
dofile('server/evidence.lua')
local replay = MZPolice.Evidence.linkCase(1, {
  caseId = 'case:0001', containerId = 'intake', instanceUid = 'evidence-uid', requestId = 'link-request-005'
})
expect(replay.ok == true and replay.replayed == true and auditCount == 1, 'replay apos restart duplicou vinculo')

local conflict = MZPolice.Evidence.linkCase(1, {
  caseId = 'case:0001', containerId = 'intake', instanceUid = 'other-uid', requestId = 'link-request-005'
})
expect(conflict.ok == false and conflict.code == 'request_id_conflict', 'requestId conflitante foi aceito')

local duplicate = MZPolice.Evidence.linkCase(1, {
  caseId = 'case:0001', containerId = 'intake', instanceUid = 'evidence-uid', requestId = 'link-request-006'
})
expect(duplicate.ok == false and duplicate.code == 'evidence_already_linked', 'vinculo duplicado foi aceito')

print('mz_police P5.1 case evidence harness: PASS cases=8')
