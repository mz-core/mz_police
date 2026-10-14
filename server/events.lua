RegisterNetEvent('mz_police:server:custody:request')
AddEventHandler('mz_police:server:custody:request', function(payload)
  local actorSource = source
  local response = MZPolice.Custody.request(actorSource, payload)
  TriggerClientEvent('mz_police:client:custody:result', actorSource, response)
end)

RegisterNetEvent('mz_police:server:custody:vehicleAck')
AddEventHandler('mz_police:server:custody:vehicleAck', function(payload)
  MZPolice.Custody.vehicleAck(source, payload)
end)

RegisterNetEvent('mz_police:server:search:open')
AddEventHandler('mz_police:server:search:open', function(payload)
  local actorSource = source
  TriggerClientEvent('mz_police:client:search:result', actorSource, MZPolice.Search.open(actorSource, payload))
end)

RegisterNetEvent('mz_police:server:search:seize')
AddEventHandler('mz_police:server:search:seize', function(payload)
  local actorSource = source
  TriggerClientEvent('mz_police:client:search:result', actorSource, MZPolice.Search.seize(actorSource, payload))
end)

RegisterNetEvent('mz_police:server:search:close')
AddEventHandler('mz_police:server:search:close', function(payload)
  local actorSource = source
  TriggerClientEvent('mz_police:client:search:result', actorSource, MZPolice.Search.close(actorSource, payload))
end)

RegisterNetEvent('mz_police:server:armory:open')
AddEventHandler('mz_police:server:armory:open', function(payload)
  local actorSource = source
  TriggerClientEvent('mz_police:client:armory:result', actorSource, MZPolice.Stations.openArmory(actorSource, payload))
end)

RegisterNetEvent('mz_police:server:armory:issue')
AddEventHandler('mz_police:server:armory:issue', function(payload)
  local actorSource = source
  TriggerClientEvent('mz_police:client:armory:result', actorSource, MZPolice.Stations.issue(actorSource, payload))
end)

RegisterNetEvent('mz_police:server:armory:return')
AddEventHandler('mz_police:server:armory:return', function(payload)
  local actorSource = source
  TriggerClientEvent('mz_police:client:armory:result', actorSource, MZPolice.Stations.returnIssued(actorSource, payload))
end)

RegisterNetEvent('mz_police:server:enforcement:scan')
AddEventHandler('mz_police:server:enforcement:scan', function(payload)
  local actorSource = source
  TriggerClientEvent('mz_police:client:enforcement:result', actorSource, MZPolice.Enforcement.scan(actorSource, payload))
end)

RegisterNetEvent('mz_police:server:enforcement:flag')
AddEventHandler('mz_police:server:enforcement:flag', function(payload)
  local actorSource = source
  TriggerClientEvent('mz_police:client:enforcement:result', actorSource, MZPolice.Enforcement.flag(actorSource, payload))
end)

RegisterNetEvent('mz_police:server:enforcement:impound')
AddEventHandler('mz_police:server:enforcement:impound', function(payload)
  local actorSource = source
  TriggerClientEvent('mz_police:client:enforcement:result', actorSource, MZPolice.Enforcement.impound(actorSource, payload))
end)

RegisterNetEvent('mz_police:server:road:place')
AddEventHandler('mz_police:server:road:place', function(payload)
  local actorSource = source
  TriggerClientEvent('mz_police:client:enforcement:result', actorSource, MZPolice.Enforcement.placeObject(actorSource, payload))
end)

RegisterNetEvent('mz_police:server:road:removeNearest')
AddEventHandler('mz_police:server:road:removeNearest', function(payload)
  local actorSource = source
  TriggerClientEvent(
    'mz_police:client:enforcement:result', actorSource, MZPolice.Enforcement.removeNearestObject(actorSource, payload)
  )
end)

RegisterNetEvent('mz_police:server:evidence:list')
AddEventHandler('mz_police:server:evidence:list', function(payload)
  local actorSource = source
  TriggerClientEvent('mz_police:client:evidence:result', actorSource, MZPolice.Evidence.list(actorSource, payload))
end)

RegisterNetEvent('mz_police:server:evidence:transfer')
AddEventHandler('mz_police:server:evidence:transfer', function(payload)
  local actorSource = source
  TriggerClientEvent('mz_police:client:evidence:result', actorSource, MZPolice.Evidence.transfer(actorSource, payload))
end)

local recordActions = {
  searchCitizens = 'searchCitizens', getCitizen = 'getCitizen', upsertRecord = 'upsertRecord',
  createCase = 'createCase', updateCase = 'updateCase', listCases = 'listCases', getCase = 'getCase',
  addCasePerson = 'addCasePerson', addCaseCharge = 'addCaseCharge', issueCitation = 'issueCitation',
  createWarrant = 'createWarrant', reviewWarrant = 'reviewWarrant'
}

for eventAction, method in pairs(recordActions) do
  RegisterNetEvent(('mz_police:server:records:%s'):format(eventAction))
  AddEventHandler(('mz_police:server:records:%s'):format(eventAction), function(payload)
    local actorSource = source
    TriggerClientEvent('mz_police:client:records:result', actorSource, {
      action = eventAction,
      response = MZPolice.Records[method](actorSource, payload)
    })
  end)
end

local prisonActions = {
  requestSentence = 'requestSentence', getSentence = 'getSentence',
  reduceSentence = 'reduceSentence', releasePrisoner = 'releasePrisoner'
}

for eventAction, method in pairs(prisonActions) do
  RegisterNetEvent(('mz_police:server:prison:%s'):format(eventAction))
  AddEventHandler(('mz_police:server:prison:%s'):format(eventAction), function(payload)
    local actorSource = source
    TriggerClientEvent('mz_police:client:prison:result', actorSource, {
      action = eventAction,
      response = MZPolice.Prison[method](actorSource, payload)
    })
  end)
end
