local function expect(condition, message)
  if not condition then error(message, 2) end
end

local now = 1000
local position = { x = 1.0, y = 1.0, z = 1.0 }
local issues, returns, audits = 0, 0, 0

function GetGameTimer() now = now + 1; return now end
function GetPlayerPed() return 10 end
function DoesEntityExist() return true end
function GetEntityCoords() return position end

MZPoliceConfig = {
  AuthorizedOrganizations = { police = true },
  Stations = {
    central = {
      label = 'Central', orgCode = 'police',
      armory = { coords = { x = 1.0, y = 1.0, z = 1.0 }, interactDistance = 2.5 }
    }
  },
  Armory = {
    capability = 'armory.basic', maximumDistance = 2.5, requestRetentionMs = 120000,
    rateLimit = { maximum = 50, windowMs = 5000 },
    catalog = {
      sidearm = { item = 'weapon_pistol', label = 'Pistola', minimumGrade = 1 },
      command = { item = 'weapon_carbinerifle', label = 'Carabina', minimumGrade = 4 }
    }
  }
}

MZPolice = {
  Policy = {
    authorize = function(source, capability, context)
      if source ~= 1 then return { ok = false, code = 'not_authorized' } end
      return {
        ok = true, identity = { source = 1, sessionId = 55, citizenid = 'POLICE1' },
        organization = { code = context.orgCode, grade = { level = 2 } }, capability = capability
      }
    end
  },
  Bridge = {
    canOrganization = function() return true end,
    listPoliceIssuedEquipment = function()
      return { { instanceUid = 'issued-uid', item = 'weapon_pistol', label = 'Pistola' } }
    end,
    issuePoliceEquipment = function(_, _, _, key, item, operationId)
      issues = issues + 1
      return { catalogKey = key, item = item, operationId = operationId }
    end,
    returnPoliceEquipment = function(_, _, _, uid, operationId)
      returns = returns + 1
      return { instanceUid = uid, operationId = operationId }
    end
  },
  Audit = { armory = function() audits = audits + 1 end }
}

dofile('server/stations.lua')

local opened = MZPolice.Stations.openArmory(1, { stationId = 'central' })
expect(opened.ok == true and #opened.catalog == 1 and opened.catalog[1].key == 'sidearm',
  'catalogo nao filtrou por cargo')
expect(opened.issued[1].instanceUid == 'issued-uid', 'itens emitidos nao foram listados')

local issued = MZPolice.Stations.issue(1, {
  stationId = 'central', catalogKey = 'sidearm', requestId = 'issue-request-1'
})
expect(issued.ok == true and issues == 1, 'emissao valida falhou')

local replay = MZPolice.Stations.issue(1, {
  stationId = 'central', catalogKey = 'sidearm', requestId = 'issue-request-1'
})
expect(replay.ok == true and issues == 1, 'replay duplicou emissao')

local conflict = MZPolice.Stations.issue(1, {
  stationId = 'central', catalogKey = 'command', requestId = 'issue-request-1'
})
expect(conflict.ok == false and conflict.code == 'request_id_conflict', 'requestId conflitante foi aceito')

local malicious = MZPolice.Stations.issue(1, {
  stationId = 'central', catalogKey = 'sidearm', requestId = 'issue-request-2', item = 'weapon_rpg'
})
expect(malicious.ok == false and malicious.code == 'invalid_payload', 'client escolheu item arbitrario')

local returned = MZPolice.Stations.returnIssued(1, {
  stationId = 'central', instanceUid = 'issued-uid', requestId = 'return-request-1'
})
expect(returned.ok == true and returns == 1, 'devolucao valida falhou')

position = { x = 50.0, y = 50.0, z = 1.0 }
local remote = MZPolice.Stations.issue(1, {
  stationId = 'central', catalogKey = 'sidearm', requestId = 'issue-request-3'
})
expect(remote.ok == false and remote.code == 'station_too_far', 'emissao remota foi aceita')

expect(audits == 2, 'mutacoes validas nao foram auditadas')
expect(MZPolice.Stations.configuredCount() == 1, 'contagem de pontos configurados incorreta')

print('mz_police P3 station armory harness: PASS cases=8')
