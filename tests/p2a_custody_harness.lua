local function expect(condition, message)
  if not condition then error(message, 2) end
end

local identities = {
  [1] = { source = 1, accountId = 10, characterId = 100, sessionId = 1000, citizenid = 'POLICE1', active = true },
  [2] = { source = 2, accountId = 20, characterId = 200, sessionId = 2000, citizenid = 'TARGET2', active = true },
  [3] = { source = 3, accountId = 30, characterId = 300, sessionId = 3000, citizenid = 'POLICE3', active = true }
}
local deaths = { [1] = 'alive', [2] = 'alive', [3] = 'alive' }
local authorized = { [1] = true, [3] = true }
local coords = {
  [1] = { x = 0.0, y = 0.0, z = 0.0 },
  [2] = { x = 1.0, y = 0.0, z = 0.0 },
  [3] = { x = 1.5, y = 0.0, z = 0.0 }
}
local buckets = { [1] = 0, [2] = 0, [3] = 0 }
local clientEvents = {}
local audits = {}
local clock = 1000

MZPoliceConfig = {
  Custody = {
    capability = 'police.custody', maximumDistance = 2.5,
    cleanupIntervalMs = 1000, rateLimit = { maximum = 50, windowMs = 5000 },
    requestRetentionMs = 120000
  }
}

MZPolice = {
  Bridge = {
    resolveIdentity = function(source)
      local identity = identities[tonumber(source)]
      if not identity then return nil, 'session_not_found' end
      local out = {}
      for key, value in pairs(identity) do out[key] = value end
      return out
    end,
    getDeathState = function(source)
      local state = deaths[tonumber(source)]
      if not state then return nil, 'player_state_unavailable' end
      return { deathState = state }
    end
  },
  Policy = {
    authorize = function(source, capability)
      if not authorized[tonumber(source)] then return { ok = false, code = 'capability_denied' } end
      return {
        ok = true,
        code = 'authorized',
        capability = capability,
        identity = identities[tonumber(source)],
        organization = { code = 'police', duty = true }
      }
    end
  },
  Audit = {
    custody = function(action, actor, target, fields)
      audits[#audits + 1] = { action = action, actor = actor, target = target, fields = fields }
      return #audits
    end,
    custodyCleanup = function(target, fields)
      audits[#audits + 1] = { action = 'cleanup', target = target, fields = fields }
      return #audits
    end
  }
}

function GetGameTimer() return clock end
function GetPlayerPed(source) return tonumber(source) * 10 end
function DoesEntityExist(entity) return entity > 0 end
function GetEntityCoords(entity) return coords[entity / 10] end
function GetPlayerRoutingBucket(source) return buckets[tonumber(source)] end
function TriggerClientEvent(name, target, payload)
  clientEvents[#clientEvents + 1] = { name = name, target = target, payload = payload }
end

dofile('server/custody.lua')

local response = MZPolice.Custody.request(1, {
  action = 'cuff', targetSource = 2, requestId = 'request-0001', expectedRevision = 0
})
expect(response.ok == true and response.revision == 1 and response.cuffed == true, 'cuff valido falhou')
expect(MZPolice.Custody.get(2).target.sessionId == 2000, 'custodia nao fixou a sessao alvo')
expect(#audits == 1 and audits[1].action == 'cuff', 'cuff nao foi auditado')

local replay = MZPolice.Custody.request(1, {
  action = 'cuff', targetSource = 2, requestId = 'request-0001', expectedRevision = 0
})
expect(replay.ok == true and replay.revision == 1 and #audits == 1, 'replay nao foi idempotente')

local conflict = MZPolice.Custody.request(1, {
  action = 'uncuff', targetSource = 2, requestId = 'request-0001', expectedRevision = 1
})
expect(conflict.ok == false and conflict.code == 'request_id_conflict', 'requestId reutilizado mudou a operacao')

local malicious = MZPolice.Custody.request(1, {
  action = 'uncuff', targetSource = 2, requestId = 'request-0002', expectedRevision = 1,
  citizenid = 'FORGED'
})
expect(malicious.ok == false and malicious.code == 'invalid_payload', 'payload aberto aceitou identity forjada')

local stale = MZPolice.Custody.request(3, {
  action = 'escort_start', targetSource = 2, requestId = 'request-0003', expectedRevision = 0
})
expect(stale.ok == false and stale.code == 'revision_conflict' and stale.revision == 1,
  'controle otimista aceitou revisao concorrente')

response = MZPolice.Custody.request(3, {
  action = 'escort_start', targetSource = 2, requestId = 'request-0004', expectedRevision = 1
})
expect(response.ok == true and response.revision == 2 and response.escortSource == 3,
  'inicio de escolta valido falhou')

buckets[3] = 9
response = MZPolice.Custody.request(3, {
  action = 'escort_stop', targetSource = 2, requestId = 'request-0005', expectedRevision = 2
})
expect(response.ok == false and response.code == 'routing_bucket_mismatch', 'bucket divergente foi aceito')
buckets[3] = 0

authorized[1] = false
MZPolice.Custody.sweep()
expect(MZPolice.Custody.get(2) == nil, 'perda de duty/capability nao limpou custodia')
expect(audits[#audits].action == 'cleanup' and audits[#audits].fields.reason == 'actor_authority_lost',
  'cleanup perdeu reason de autoridade')
authorized[1] = true

response = MZPolice.Custody.request(1, {
  action = 'cuff', targetSource = 2, requestId = 'request-0006', expectedRevision = 0
})
expect(response.ok == true, 'segundo cuff valido falhou')
deaths[2] = 'dead'
MZPolice.Custody.sweep()
expect(MZPolice.Custody.get(2) == nil, 'morte do alvo nao limpou custodia')
deaths[2] = 'alive'

response = MZPolice.Custody.request(1, {
  action = 'cuff', targetSource = 2, requestId = 'request-0007', expectedRevision = 0
})
expect(response.ok == true, 'terceiro cuff valido falhou')
identities[2].sessionId = 2001
MZPolice.Custody.sweep()
expect(MZPolice.Custody.get(2) == nil, 'source reuse nao limpou custodia')

identities[2].sessionId = 2002
response = MZPolice.Custody.request(1, {
  action = 'cuff', targetSource = 2, requestId = 'request-0008', expectedRevision = 0
})
expect(response.ok == true, 'quarto cuff valido falhou')
MZPolice.Custody.cleanupSource(1, 'player_dropped')
expect(MZPolice.Custody.get(2) == nil, 'disconnect do ator nao limpou custodia')

coords[2] = { x = 10.0, y = 0.0, z = 0.0 }
response = MZPolice.Custody.request(1, {
  action = 'cuff', targetSource = 2, requestId = 'request-0009', expectedRevision = 0
})
expect(response.ok == false and response.code == 'target_too_far', 'alvo distante foi algemado')

coords[2] = { x = 1.0, y = 0.0, z = 0.0 }
response = MZPolice.Custody.request(1, {
  action = 'cuff', targetSource = 2, requestId = 'request-0010', expectedRevision = 0
})
expect(response.ok == true and response.revision == 1, 'cuff para teste de sync falhou')
response = MZPolice.Custody.request(1, {
  action = 'uncuff', targetSource = 2, requestId = 'request-0011', expectedRevision = 1
})
expect(response.ok == true and response.revision == 2 and response.cuffed == false, 'uncuff valido falhou')
local lastClientEvent = clientEvents[#clientEvents]
expect(lastClientEvent.target == 2 and lastClientEvent.payload.revision == 2
  and lastClientEvent.payload.cuffed == false, 'uncuff nao sincronizou a revisao terminal')

print('mz_police P2A custody harness: PASS cases=16')
