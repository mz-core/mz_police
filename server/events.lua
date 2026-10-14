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
