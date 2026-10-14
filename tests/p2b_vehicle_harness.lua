local function expect(condition, message)
  if not condition then error(message, 2) end
end

local identities = {
  [1] = { source = 1, accountId = 10, characterId = 100, sessionId = 1000, citizenid = 'POLICE1', active = true },
  [2] = { source = 2, accountId = 20, characterId = 200, sessionId = 2000, citizenid = 'TARGET2', active = true }
}
local positions = {
  [10] = { x = 0.0, y = 0.0, z = 0.0 },
  [20] = { x = 1.0, y = 0.0, z = 0.0 },
  [100] = { x = 2.0, y = 0.0, z = 0.0 }
}
local entityBuckets = { [100] = 0 }
local occupiedSeats = {}
local targetVehicle = 0

MZPoliceConfig = {
  Custody = {
    capability = 'police.custody', maximumDistance = 2.5, vehicleMaximumDistance = 5.0,
    cleanupIntervalMs = 1000, rateLimit = { maximum = 20, windowMs = 5000 },
    requestRetentionMs = 120000
  }
}

MZPolice = {
  Bridge = {
    resolveIdentity = function(source) return identities[tonumber(source)] or nil, 'session_not_found' end,
    getDeathState = function() return { deathState = 'alive' } end
  },
  Policy = {
    authorize = function(source, capability)
      return {
        ok = true, code = 'authorized', capability = capability,
        identity = identities[tonumber(source)], organization = { code = 'police', duty = true }
      }
    end
  },
  Audit = { custody = function() return 1 end, custodyCleanup = function() return 1 end }
}

function GetGameTimer() return 1000 end
function GetPlayerPed(source) return tonumber(source) * 10 end
function DoesEntityExist(entity) return positions[entity] ~= nil end
function IsEntityAVehicle(entity) return entity == 100 end
function GetEntityCoords(entity) return positions[entity] end
function GetPlayerRoutingBucket() return 0 end
function GetEntityRoutingBucket(entity) return entityBuckets[entity] end
function GetAllVehicles() return { 100 } end
function GetVehicleMaxNumberOfPassengers() return 2 end
function GetPedInVehicleSeat(_, seat) return occupiedSeats[seat] or 0 end
function NetworkGetNetworkIdFromEntity(entity) return entity == 100 and 900 or 0 end
function GetVehiclePedIsIn(ped) return ped == 20 and targetVehicle or 0 end
function TriggerClientEvent() end

dofile('server/custody.lua')

local response = MZPolice.Custody.request(1, {
  action = 'cuff', targetSource = 2, requestId = 'vehicle-0001', expectedRevision = 0
})
expect(response.ok == true and response.revision == 1, 'precondicao cuff falhou')

response = MZPolice.Custody.request(1, {
  action = 'vehicle_put', targetSource = 2, requestId = 'vehicle-0002', expectedRevision = 1
})
expect(response.ok == true and response.revision == 2 and response.vehicleNetId == 900
  and response.vehicleSeat == 0, 'colocacao em assento derivado falhou')
targetVehicle = 100
expect(MZPolice.Custody.vehicleAck(2, { revision = 2, networkId = 900 }) == true,
  'ack do alvo no veiculo valido falhou')
expect(MZPolice.Custody.vehicleAck(1, { revision = 2, networkId = 900 }) == false,
  'ator confirmou o assento pelo alvo')

response = MZPolice.Custody.request(1, {
  action = 'escort_start', targetSource = 2, requestId = 'vehicle-0003', expectedRevision = 2
})
expect(response.ok == false and response.code == 'target_in_vehicle', 'escolta iniciou dentro do veiculo')

response = MZPolice.Custody.request(1, {
  action = 'vehicle_remove', targetSource = 2, requestId = 'vehicle-0004', expectedRevision = 2
})
expect(response.ok == true and response.revision == 3 and response.vehicleNetId == nil,
  'retirada de veiculo existente falhou')

response = MZPolice.Custody.request(1, {
  action = 'vehicle_put', targetSource = 2, requestId = 'vehicle-0005', expectedRevision = 3,
  vehicleNetId = 12345
})
expect(response.ok == false and response.code == 'invalid_payload', 'cliente escolheu veiculo arbitrario')

entityBuckets[100] = 7
response = MZPolice.Custody.request(1, {
  action = 'vehicle_put', targetSource = 2, requestId = 'vehicle-0006', expectedRevision = 3
})
expect(response.ok == false and response.code == 'vehicle_seat_unavailable', 'veiculo cross-bucket foi aceito')
entityBuckets[100] = 0

occupiedSeats[0], occupiedSeats[1] = 111, 112
response = MZPolice.Custody.request(1, {
  action = 'vehicle_put', targetSource = 2, requestId = 'vehicle-0007', expectedRevision = 3
})
expect(response.ok == false and response.code == 'vehicle_seat_unavailable', 'assento ocupado foi aceito')

print('mz_police P2B vehicle harness: PASS cases=9')
