local function expect(condition, message)
  if not condition then error(message, 2) end
end

local now, scans, flags, impounds, audits = 1000, 0, 0, 0, 0
local entities = { [10] = true }
function GetGameTimer() now = now + 1; return now end
function GetPlayerPed() return 10 end
function DoesEntityExist(entity) return entities[entity] == true end
function GetEntityCoords(entity) return entity == 10 and { x = 0, y = 0, z = 0 } or { x = 2, y = 0, z = 0 } end
function GetEntityForwardVector() return { x = 1, y = 0, z = 0 } end
function GetEntityHeading() return 90.0 end
function GetHashKey() return 123 end
function CreateObjectNoOffset() entities[20] = true; return 20 end
function SetEntityHeading() end
function FreezeEntityPosition() end
function DeleteEntity(entity) entities[entity] = nil end

MZPoliceConfig = {
  Enforcement = {
    scanDistance = 12, rateLimit = { maximum = 50, windowMs = 5000 }, requestRetentionMs = 120000,
    flags = { stolen = { label = 'Stolen' } },
    impoundReasons = { court = { label = 'Court order', reason = 'court_order' } }
  },
  RoadObjects = {
    capability = 'police.road.tools', placementDistance = 2, removalDistance = 8,
    maximumPerOfficer = 2, maximumGlobal = 5,
    types = { cone = { label = 'Cone', model = 'prop_cone' } }
  }
}
MZPolice = {
  Policy = {
    authorize = function(source, capability)
      if source ~= 1 then return { ok = false, code = 'denied' } end
      return {
        ok = true, capability = capability,
        identity = { source = 1, sessionId = 55, citizenid = 'POLICE1' },
        organization = { code = 'police' }
      }
    end
  },
  Bridge = {
    scanNearestVehicle = function()
      scans = scans + 1
      return { scanId = 'scan-1', plate = 'POL123', model = 'police', state = 'out', speedKph = 80, flags = {} }
    end,
    setVehicleFlag = function(_, scanId, code)
      flags = flags + 1
      return { plate = 'POL123', scanId = scanId, flagCode = code }
    end,
    impoundScannedVehicle = function()
      impounds = impounds + 1
      return { plate = 'POL123', state = 'impounded' }
    end
  },
  Audit = { enforcement = function() audits = audits + 1 end }
}

dofile('server/enforcement.lua')

local scan = MZPolice.Enforcement.scan(1, { mode = 'anpr', requestId = 'scan-request-1' })
expect(scan.ok == true and scans == 1 and scan.vehicle.plate == 'POL123', 'ANPR valido falhou')
expect(#scan.flagOptions == 1 and #scan.impoundReasons == 1, 'opcoes configuradas nao foram retornadas')

local malicious = MZPolice.Enforcement.scan(1, { mode = 'anpr', requestId = 'scan-request-2', plate = 'FORGED' })
expect(malicious.ok == false and malicious.code == 'invalid_payload', 'client forjou placa')

local flagged = MZPolice.Enforcement.flag(1, {
  scanId = 'scan-1', flagCode = 'stolen', active = true, reference = 'CASE-1', requestId = 'flag-request-1'
})
expect(flagged.ok == true and flags == 1, 'flag configurada falhou')
local replay = MZPolice.Enforcement.flag(1, {
  scanId = 'scan-1', flagCode = 'stolen', active = true, reference = 'CASE-1', requestId = 'flag-request-1'
})
expect(replay.ok == true and flags == 1, 'replay duplicou flag')

local impounded = MZPolice.Enforcement.impound(1, {
  scanId = 'scan-1', reasonCode = 'court', reference = 'CASE-1', requestId = 'impound-request-1'
})
expect(impounded.ok == true and impounds == 1, 'impound configurado falhou')

local badReason = MZPolice.Enforcement.impound(1, {
  scanId = 'scan-1', reasonCode = 'invented', reference = '', requestId = 'impound-request-2'
})
expect(badReason.ok == false and badReason.code == 'impound_reason_not_configured', 'motivo inventado foi aceito')

local placed = MZPolice.Enforcement.placeObject(1, { objectType = 'cone', requestId = 'road-request-1' })
expect(placed.ok == true and entities[20] == true, 'objeto viario nao foi criado no servidor')
local removed = MZPolice.Enforcement.removeNearestObject(1, { requestId = 'road-request-2' })
expect(removed.ok == true and entities[20] == nil, 'objeto viario nao foi removido')

expect(audits == 5, 'operacoes nao foram auditadas')
print('mz_police P4 enforcement harness: PASS cases=8')
