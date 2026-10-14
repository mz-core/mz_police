local function expect(condition, message) if not condition then error(message, 2) end end
local now, transfers, audits = 1000, 0, 0
function GetGameTimer() now = now + 1; return now end

MZPoliceConfig = { Evidence = {
  listCapability = 'police.evidence.collect', manageCapability = 'police.evidence.manage',
  requestRetentionMs = 120000, rateLimit = { maximum = 20, windowMs = 5000 },
  occurrenceAssociationEnabled = false,
  containers = { intake = { label = 'Intake' }, locker = { label = 'Locker' } }
} }
MZPolice = {
  Policy = { authorize = function(source, capability)
    if source ~= 1 then return { ok = false, code = 'denied' } end
    return { ok = true, capability = capability, identity = { sessionId = 55, citizenid = 'POLICE1' }, organization = { code = 'police' } }
  end },
  Bridge = {
    listPoliceEvidence = function() return { { instanceUid = 'evidence-uid', evidence = { revision = 1 } } } end,
    transferPoliceEvidence = function(_, _, fromContainer, toContainer, uid)
      transfers = transfers + 1
      return { instanceUid = uid, fromContainer = fromContainer, toContainer = toContainer, evidence = { revision = 2 } }
    end
  },
  Audit = { evidence = function() audits = audits + 1 end }
}

dofile('server/evidence.lua')

local listed = MZPolice.Evidence.list(1, { containerId = 'intake' })
expect(listed.ok == true and listed.items[1].instanceUid == 'evidence-uid', 'listagem autorizada falhou')
local moved = MZPolice.Evidence.transfer(1, {
  fromContainer = 'intake', toContainer = 'locker', instanceUid = 'evidence-uid', requestId = 'evidence-request-1'
})
expect(moved.ok == true and transfers == 1 and audits == 1, 'transferencia autorizada falhou')
local replay = MZPolice.Evidence.transfer(1, {
  fromContainer = 'intake', toContainer = 'locker', instanceUid = 'evidence-uid', requestId = 'evidence-request-1'
})
expect(replay.ok == true and transfers == 1, 'replay duplicou transferencia')
local conflict = MZPolice.Evidence.transfer(1, {
  fromContainer = 'locker', toContainer = 'intake', instanceUid = 'evidence-uid', requestId = 'evidence-request-1'
})
expect(conflict.ok == false and conflict.code == 'request_id_conflict', 'requestId conflitante foi aceito')
local forged = MZPolice.Evidence.transfer(1, {
  fromContainer = 'intake', toContainer = 'locker', instanceUid = 'evidence-uid', requestId = 'evidence-request-2', occurrenceId = 9
})
expect(forged.ok == false and forged.code == 'invalid_payload', 'associacao de ocorrencia nao aprovada foi aceita')
local unknown = MZPolice.Evidence.list(1, { containerId = 'invented' })
expect(unknown.ok == false and unknown.code == 'evidence_container_not_configured', 'container inventado foi aceito')

print('mz_police P5 evidence harness: PASS cases=6')
