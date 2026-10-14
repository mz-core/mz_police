local function expect(condition, message) if not condition then error(message, 2) end end

local now, sentenceCalls, cleanupCalls, audits = 1000, 0, 0, 0
local caseMode = 'valid'
function GetGameTimer() now = now + 1; return now end
function GetPlayerRoutingBucket() return 0 end
function GetPlayerPed(source) return source + 100 end
function GetEntityCoords(entity)
  return entity == 101 and { x = 0, y = 0, z = 0 } or { x = 1, y = 0, z = 0 }
end

MZPoliceConfig = { Prison = {
  enabled = false, sentenceCapability = 'police.arrest.request', reviewCapability = 'reports.approve',
  readCapability = 'mdt.open', maximumDistance = 3.0,
  rateLimit = { maximum = 50, windowMs = 5000 }
} }
MZPolice = {
  Policy = { authorize = function(source, capability)
    if source ~= 1 then return { ok = false, code = 'capability_denied' } end
    return { ok = true, capability = capability, identity = { citizenid = 'OFFICER1', sessionId = 77 }, organization = { code = 'police' } }
  end },
  Custody = {
    get = function(target)
      return target == 2 and { cuffed = true, cuffedBy = { source = 1 }, target = { citizenid = 'TARGET1' } } or nil
    end,
    cleanupSource = function() cleanupCalls = cleanupCalls + 1 end
  },
  RecordsRepository = { getCase = function(orgCode, caseId)
    if caseMode == 'missing' then return nil end
    return {
      public_id = caseId, org_code = orgCode,
      charges = caseMode == 'unrelated' and {
        { citizenid = 'OTHER', rule_code = 'custodial', sentence_seconds = 120 }
      } or {
        { citizenid = 'TARGET1', rule_code = 'custodial', sentence_seconds = 120 }
      }
    }
  end },
  Bridge = {
    requestSentence = function(_, _, request)
      sentenceCalls = sentenceCalls + 1
      return { public_id = 'sentence:' .. request.operationId, status = 'active' }
    end,
    getSentence = function(citizenid) return { target_citizenid = citizenid, status = 'active' } end,
    reduceSentence = function(_, citizenid) return { target_citizenid = citizenid, remaining_seconds = 30 } end,
    releasePrisoner = function(_, citizenid) return { target_citizenid = citizenid, status = 'released' } end
  },
  Audit = { prison = function() audits = audits + 1 end }
}

dofile('server/prison.lua')

local payload = { targetSource = 2, caseId = 'case:0001', ruleCode = 'custodial', requestId = 'request_sentence_01' }
expect(MZPolice.Prison.requestSentence(1, payload).code == 'prison_integration_disabled', 'integracao desabilitada foi usada')
MZPoliceConfig.Prison.enabled = true
expect(MZPolice.Prison.requestSentence(2, payload).code == 'capability_denied', 'ator sem capability foi aceito')
expect(MZPolice.Prison.requestSentence(1, {
  targetSource = 2, caseId = 'case:0001', ruleCode = 'custodial', requestId = 'request_sentence_02', durationSeconds = 1
}).code == 'invalid_payload', 'duracao client-authoritative foi aceita')
expect(MZPolice.Prison.requestSentence(1, {
  targetSource = 3, caseId = 'case:0001', ruleCode = 'custodial', requestId = 'request_sentence_03'
}).code == 'custody_required', 'alvo sem custodia foi aceito')

caseMode = 'missing'
expect(MZPolice.Prison.requestSentence(1, payload).code == 'case_not_found', 'caso inexistente foi aceito')
caseMode = 'unrelated'
expect(MZPolice.Prison.requestSentence(1, payload).code == 'sentence_charge_not_found', 'cargo sem vinculo ao alvo foi aceito')
caseMode = 'valid'
local started = MZPolice.Prison.requestSentence(1, payload)
expect(started.ok == true and sentenceCalls == 1 and cleanupCalls == 1, 'sentenca valida falhou')
local read = MZPolice.Prison.getSentence(1, { citizenid = 'TARGET1' })
expect(read.ok == true and read.sentence.status == 'active', 'consulta de sentenca falhou')
local reduced = MZPolice.Prison.reduceSentence(1, {
  citizenid = 'TARGET1', ruleCode = 'work', requestId = 'request_reduce_01'
})
expect(reduced.ok == true and reduced.sentence.remaining_seconds == 30, 'reducao autorizada falhou')
local released = MZPolice.Prison.releasePrisoner(1, {
  citizenid = 'TARGET1', reasonCode = 'court', requestId = 'request_release_01'
})
expect(released.ok == true and released.sentence.status == 'released', 'soltura autorizada falhou')
expect(audits == 3, 'auditoria policial incompleta')

print('mz_police P7 prison harness: PASS cases=11')
