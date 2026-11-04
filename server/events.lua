local accessWindows = {}
local accessLogAt = {}
local restraintRefreshAt = {}

RegisterNetEvent('mz_police:server:dispatch:panic', function(payload)
  local actorSource = source
  local requestId = type(payload) == 'table' and tostring(payload.requestId or '') or ''
  local valid = type(payload) == 'table'
  if valid then
    for key in pairs(payload) do
      if key ~= 'requestId' then valid = false; break end
    end
  end
  if #requestId < 8 or #requestId > 64 or not requestId:match('^[%w:_-]+$') then valid = false end

  local response
  if not valid then
    response = { ok = false, code = 'invalid_request' }
  elseif GetResourceState('mz_dispatch') ~= 'started' then
    response = { ok = false, code = 'dispatch_unavailable' }
  else
    local capability = tostring((MZPoliceConfig.Records or {}).readCapability or 'mdt.open')
    local authorization = MZPolice.Policy.authorize(actorSource, capability, { orgCode = 'police' })
    if authorization.ok ~= true then
      response = { ok = false, code = tostring(authorization.code or 'not_authorized') }
    else
      local exportOk, result = pcall(function()
        return exports['mz_dispatch']:CreatePolicePanicCall(actorSource, requestId)
      end)
      if exportOk ~= true then
        print(('[mz_police][dispatch] panic contract failed source=%s'):format(tostring(actorSource)))
        response = { ok = false, code = 'dispatch_contract_failed' }
      elseif type(result) ~= 'table' then
        response = { ok = false, code = 'invalid_dispatch_response' }
      else
        response = result
      end
      MZPolice.Audit.records('dispatch_panic', authorization.identity, {
        operationId = requestId,
        result = tostring(response.code or 'unknown'),
        entityId = type(response.call) == 'table' and response.call.public_id or nil,
        entityType = 'dispatch_call'
      })
    end
  end

  TriggerClientEvent('mz_police:client:dispatchPanicResult', actorSource, {
    requestId = requestId,
    response = response
  })
end)

-- Confirma identidade, organizacao policial e duty antes de montar o radial.
-- Cada acao operacional continua exigindo sua propria capability no servidor.
RegisterNetEvent('mz_police:server:requestAccess', function()
  local actorSource = source
  local now = GetGameTimer()
  if accessWindows[actorSource] and now - accessWindows[actorSource] < 3000 then return end
  accessWindows[actorSource] = now
  local decision = MZPolice.Policy.authorizeDuty(actorSource)
  if decision.ok ~= true then
    local previous = accessLogAt[actorSource]
    if not previous or previous.code ~= decision.code or now - previous.at >= 30000 then
      accessLogAt[actorSource] = { code = decision.code, at = now }
      print(('[mz_police][target] access denied source=%s code=%s'):format(
        tostring(actorSource), tostring(decision.code)
      ))
    end
  end
  TriggerClientEvent('mz_police:client:access', actorSource, {
    ok = decision.ok == true,
    code = tostring(decision.code or 'not_authorized')
  })
end)

AddEventHandler('playerDropped', function()
  accessWindows[source] = nil
  accessLogAt[source] = nil
  restraintRefreshAt[source] = nil
end)

RegisterNetEvent('mz_police:server:custody:request')
AddEventHandler('mz_police:server:custody:request', function(payload)
  local actorSource = source
  local action = type(payload) == 'table' and tostring(payload.action or ''):lower() or ''
  local response
  if action == 'cuff' or action == 'uncuff' then
    -- Algemar/desalgemar passam pelo orquestrador de restricoes (itens,
    -- APPLYING, auditoria). Escolta, transferencia e veiculo continuam na custodia.
    response = MZPolice.Restraints.request(actorSource, payload, 'service')
  else
    response = MZPolice.Custody.request(actorSource, payload)
  end
  if type(response) == 'table' and response.ok ~= true
    and type(MZPoliceConfig.Debug) == 'table' and MZPoliceConfig.Debug.verboseErrors == true then
    print(('[mz_police][custody] actor=%s target=%s action=%s code=%s'):format(
      tostring(actorSource), tostring(type(payload) == 'table' and payload.targetSource or ''),
      tostring(action), tostring(response.code)))
  end
  TriggerClientEvent('mz_police:client:custody:result', actorSource, response)
end)

RegisterNetEvent('mz_police:server:restraints:request')
AddEventHandler('mz_police:server:restraints:request', function(payload)
  local actorSource = source
  local channel = type(payload) == 'table' and tostring(payload.channel or ''):lower() or ''
  local requestPayload = {}
  if type(payload) == 'table' then
    for key, value in pairs(payload) do
      if key ~= 'channel' and key ~= 'command' then requestPayload[key] = value end
    end
  end
  local response = MZPolice.Restraints.request(actorSource, requestPayload, channel)
  if type(response) == 'table' and response.ok ~= true
    and type(MZPoliceConfig.Debug) == 'table' and MZPoliceConfig.Debug.verboseErrors == true then
    print(('[mz_police][restraints] actor=%s target=%s action=%s channel=%s code=%s'):format(
      tostring(actorSource), tostring(requestPayload.targetSource), tostring(requestPayload.action),
      tostring(channel), tostring(response.code)))
  end
  TriggerClientEvent('mz_police:client:restraints:result', actorSource, {
    action = tostring(requestPayload.action or ''),
    targetSource = tonumber(requestPayload.targetSource),
    response = response
  })
end)

RegisterNetEvent('mz_police:server:restraints:refresh')
AddEventHandler('mz_police:server:restraints:refresh', function()
  local actorSource = source
  local current = GetGameTimer()
  local previous = restraintRefreshAt[actorSource] or 0
  if current - previous < 1500 then return end
  restraintRefreshAt[actorSource] = current
  TriggerClientEvent('mz_police:client:restraints:access', actorSource,
    MZPolice.Restraints.access(actorSource))
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

RegisterNetEvent('mz_police:server:evidence:linkCase')
AddEventHandler('mz_police:server:evidence:linkCase', function(payload)
  local actorSource = source
  TriggerClientEvent('mz_police:client:evidence:linkResult', actorSource, MZPolice.Evidence.linkCase(actorSource, payload))
end)

local recordActions = {
  searchCitizens = 'searchCitizens', getCitizen = 'getCitizen', lookupVehicle = 'lookupVehicle', getLegalCatalog = 'getLegalCatalog', upsertRecord = 'upsertRecord',
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

local arrestActions = {
  preview = 'preview', quote = 'quote', commit = 'commit'
}

for eventAction, method in pairs(arrestActions) do
  RegisterNetEvent(('mz_police:server:arrest:%s'):format(eventAction))
  AddEventHandler(('mz_police:server:arrest:%s'):format(eventAction), function(payload)
    local actorSource = source
    local requestId = type(payload) == 'table' and tostring(payload.requestId or '') or ''
    TriggerClientEvent('mz_police:client:arrest:result', actorSource, {
      action = eventAction,
      requestId = requestId,
      response = MZPolice.Arrest[method](actorSource, payload)
    })
  end)
end

RegisterNetEvent('mz_police:server:citations:pay')
AddEventHandler('mz_police:server:citations:pay', function(payload)
  local actorSource = source
  TriggerClientEvent('mz_police:client:citations:result', actorSource, MZPolice.Records.payCitation(actorSource, payload))
end)

RegisterNetEvent('mz_police:server:citations:requestPayment')
AddEventHandler('mz_police:server:citations:requestPayment', function(payload)
  local actorSource = source
  TriggerClientEvent('mz_police:client:records:result', actorSource, {
    action = 'requestCitationPayment',
    response = MZPolice.Records.requestCitationPayment(actorSource, payload)
  })
end)

local interactionActions = {
  context = 'context', identify = 'identify', openMdt = 'openMdt', processArrest = 'processArrest'
}

for eventAction, method in pairs(interactionActions) do
  RegisterNetEvent(('mz_police:server:interaction:%s'):format(eventAction))
  AddEventHandler(('mz_police:server:interaction:%s'):format(eventAction), function(payload)
    local actorSource = source
    TriggerClientEvent('mz_police:client:interaction:result', actorSource, {
      action = eventAction,
      response = MZPolice.Interactions[method](actorSource, payload)
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

RegisterNetEvent('mz_police:server:advanced:request')
AddEventHandler('mz_police:server:advanced:request', function(envelope)
  local actorSource = source
  local action = type(envelope) == 'table' and tostring(envelope.action or '') or ''
  local requestId = type(envelope) == 'table' and tostring(envelope.requestId or '') or ''
  TriggerClientEvent('mz_police:client:advanced:response', actorSource, {
    action = action,
    requestId = requestId,
    response = MZPolice.Advanced.request(actorSource, envelope)
  })
end)
