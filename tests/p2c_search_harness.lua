local function expect(condition, message)
  if not condition then error(message, 2) end
end

local identities = {
  [1] = { source = 1, accountId = 10, characterId = 100, sessionId = 1000, citizenid = 'POLICE1' },
  [2] = { source = 2, accountId = 20, characterId = 200, sessionId = 2000, citizenid = 'TARGET2' }
}
local revoked = 0
local transfers = 0
function GetGameTimer() return 1000 end

MZPoliceConfig = { Search = {
  grantTtlSeconds = 30, sessionRetentionSeconds = 45, defaultEvidenceContainer = 'intake',
  rateLimit = { maximum = 20, windowMs = 5000 }
} }
MZPolice = {
  Policy = {
    authorize = function(source, capability)
      if source ~= 1 then return { ok = false, code = 'session_not_found' } end
      return {
        ok = true, code = 'authorized', capability = capability, identity = identities[1],
        organization = { code = 'police', duty = true }
      }
    end
  },
  Custody = {
    get = function(source)
      if source ~= 2 then return nil end
      return { cuffed = true, target = identities[2], revision = 1 }
    end
  },
  Bridge = {
    resolveIdentity = function(source) return identities[source] or nil, 'session_not_found' end,
    canOrganization = function(_, orgCode, capability)
      return orgCode == 'police' and capability == 'police.seize'
    end,
    createInventoryGrant = function(_, _, purpose)
      return { grantToken = 'grant-token-0001', purpose = purpose, expiresAt = os.time() + 30 }
    end,
    getGrantedInventory = function()
      return { inventory = { main = { slots = {} }, equipment = { slots = {} } } }
    end,
    transferGrantedItem = function(_, _, instanceUid, amount, destination, operationId)
      transfers = transfers + 1
      return {
        instanceUid = instanceUid, amount = amount, destination = destination, operationId = operationId,
        metadata = { serial = 'SERIAL-1' }
      }
    end,
    revokeInventoryGrant = function() revoked = revoked + 1; return true end
  }
}

dofile('server/search.lua')

local opened = MZPolice.Search.open(1, { targetSource = 2, requestId = 'search-0001' })
expect(opened.ok == true and opened.code == 'search_opened' and opened.canSeize == true,
  'busca autorizada falhou')
expect(opened.grantToken == nil, 'token interno vazou para o client')

local replay = MZPolice.Search.open(1, { targetSource = 2, requestId = 'search-0001' })
expect(replay.ok == true and replay.searchId == 'search-0001', 'reabertura idempotente falhou')

local seized = MZPolice.Search.seize(1, {
  searchId = 'search-0001', instanceUid = 'uid-0001', amount = 1,
  operationId = 'operation-0001', containerId = 'intake'
})
expect(seized.ok == true and seized.code == 'item_seized' and transfers == 1,
  'apreensao orquestrada falhou')
expect(seized.transfer.metadata.serial == 'SERIAL-1', 'metadata foi perdida')

local forged = MZPolice.Search.seize(1, {
  searchId = 'search-0001', instanceUid = 'uid-0002', amount = 1,
  operationId = 'operation-0002', containerId = 'intake', targetCitizenid = 'FORGED'
})
expect(forged.ok == false and forged.code == 'invalid_payload', 'payload forjou identity')

local closed = MZPolice.Search.close(1, { searchId = 'search-0001' })
expect(closed.ok == true and revoked == 1, 'fechamento nao revogou grant')

local missing = MZPolice.Search.seize(1, {
  searchId = 'search-0001', instanceUid = 'uid-0001', amount = 1,
  operationId = 'operation-0003', containerId = 'intake'
})
expect(missing.ok == false and missing.code == 'search_session_not_found', 'sessao encerrada aceitou mutacao')

print('mz_police P2C search harness: PASS cases=6')
