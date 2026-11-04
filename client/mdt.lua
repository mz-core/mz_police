MZPoliceClient = MZPoliceClient or {}

local mdtOpen = false
local opening = false
local openingContext
local activeContext
local requestSequence = 0
local pending = {}
-- Deduplicacao dos eventos de tempo real pelo ID canonico do chamado.
-- Limitada em tamanho para nao crescer durante a sessao.
local dispatchSeen = {}
local dispatchSeenOrder = {}

local events = {
  searchCitizens = 'mz_police:server:records:searchCitizens',
  getCitizen = 'mz_police:server:records:getCitizen',
  lookupVehicle = 'mz_police:server:records:lookupVehicle',
  getLegalCatalog = 'mz_police:server:records:getLegalCatalog',
  upsertRecord = 'mz_police:server:records:upsertRecord',
  createCase = 'mz_police:server:records:createCase',
  listCases = 'mz_police:server:records:listCases',
  getCase = 'mz_police:server:records:getCase',
  updateCase = 'mz_police:server:records:updateCase',
  addCasePerson = 'mz_police:server:records:addCasePerson',
  addCaseCharge = 'mz_police:server:records:addCaseCharge',
  requestCitationPayment = 'mz_police:server:citations:requestPayment',
  arrestPreview = 'mz_police:server:arrest:preview',
  arrestQuote = 'mz_police:server:arrest:quote',
  arrestCommit = 'mz_police:server:arrest:commit',
  getSentence = 'mz_police:server:prison:getSentence',
  evidenceList = 'mz_police:server:evidence:list',
  evidenceLink = 'mz_police:server:evidence:linkCase',
  forensicAnalyze = 'mz_police_advanced',
  trackerSnapshot = 'mz_police_advanced',
  trackerBroadcast = 'mz_police_advanced',
  dispatchList = 'mz_dispatch',
  dispatchAccept = 'mz_dispatch',
  dispatchClose = 'mz_dispatch',
  dispatchWaypoint = 'mz_navigation',
  dispatchPanic = 'mz_police:server:dispatch:panic'
}

local dispatchActions = {
  dispatchList = 'list',
  dispatchAccept = 'accept',
  dispatchClose = 'close'
}

local function notify(message, kind)
  if type(MZPoliceClient.Notify) == 'function' then
    MZPoliceClient.Notify(message, kind, 'MDT policial')
  else
    print(('[mz_police] %s'):format(tostring(message)))
  end
end

local function dispatchLog(action, callId, detail)
  local settings = type(MZPoliceConfig) == 'table' and MZPoliceConfig.Dispatch or nil
  if type(settings) ~= 'table' or settings.debug ~= true then return end
  print(('[mz_police][dispatch] %s call_id=%s %s'):format(
    tostring(action), tostring(callId or '-'), tostring(detail or '')))
end

local function rememberDispatchCall(callId)
  local settings = type(MZPoliceConfig) == 'table' and MZPoliceConfig.Dispatch or nil
  local limit = math.max(1, math.floor(tonumber(settings and settings.seenCallLimit) or 128))
  if dispatchSeen[callId] then return false end
  dispatchSeen[callId] = true
  dispatchSeenOrder[#dispatchSeenOrder + 1] = callId
  while #dispatchSeenOrder > limit do
    local oldest = table.remove(dispatchSeenOrder, 1)
    dispatchSeen[oldest] = nil
  end
  return true
end

local function requestDispatchRefresh()
  if not mdtOpen then return end
  SendNUIMessage({ type = 'mdt:dispatch:refresh' })
end

local function requestMdtDataRefresh(scope)
  if not mdtOpen then return end
  SendNUIMessage({ type = 'mdt:data:refresh', scope = tostring(scope or 'all') })
end

local function closeMdt()
  if not mdtOpen then return end
  mdtOpen = false
  activeContext = nil
  if MZPoliceClient.Tracker then MZPoliceClient.Tracker.SetMdtActive(false) end
  pending = {}
  dispatchSeen = {}
  dispatchSeenOrder = {}
  SetNuiFocus(false, false)
  SendNUIMessage({ type = 'mdt:close' })
end

local function sendResult(action, response)
  local request = pending[action]
  if not request then return end
  pending[action] = nil
  SendNUIMessage({
    type = 'mdt:result',
    action = action,
    requestId = request.id,
    response = type(response) == 'table' and response or { ok = false, code = 'invalid_response' }
  })
end

RegisterNetEvent('mz_police:client:records:result', function(result)
  result = type(result) == 'table' and result or {}
  local action = tostring(result.action or '')
  local response = type(result.response) == 'table' and result.response or { ok = false, code = 'invalid_response' }

  if opening and action == 'listCases' then
    opening = false
    if response.ok ~= true then
      notify(('MDT negado: %s'):format(tostring(response.code or 'unknown')), 'error')
      return
    end
    local bootstrap = response
    bootstrap.trackerV2 = MZPoliceClient.Tracker
      and MZPoliceClient.Tracker.IsEnabled() == true or false
    local trackerConfig = type(MZPoliceConfig) == 'table' and MZPoliceConfig.TrackerV2 or {}
    bootstrap.trackerV2Config = {
      tickMs = tonumber(trackerConfig.TickMs) or 1000,
      staleAfterMs = tonumber(trackerConfig.StaleAfterMs) or 5000,
      teleportThreshold = tonumber(trackerConfig.TeleportThreshold) or 250
    }
    if openingContext then
      bootstrap.selectedCitizen = openingContext.selectedCitizen
      bootstrap.targetSource = openingContext.targetSource
      bootstrap.processing = openingContext.processing
    end
    activeContext = openingContext
    openingContext = nil
    mdtOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ type = 'mdt:open', bootstrap = bootstrap })
    return
  end

  sendResult(action, response)
  if response.ok == true then
    if action == 'createCase' or action == 'updateCase' or action == 'addCasePerson'
      or action == 'addCaseCharge' then
      requestMdtDataRefresh('cases')
    elseif action == 'upsertRecord' then
      requestMdtDataRefresh('citizen')
    end
  end
end)

RegisterNetEvent('mz_police:client:evidence:result', function(response)
  sendResult('evidenceList', response)
end)

RegisterNetEvent('mz_police:client:evidence:linkResult', function(response)
  sendResult('evidenceLink', response)
end)

RegisterNetEvent('mz_police:client:prison:result', function(result)
  result = type(result) == 'table' and result or {}
  sendResult(tostring(result.action or ''), result.response)
end)

RegisterNetEvent('mz_police:client:arrest:result', function(result)
  result = type(result) == 'table' and result or {}
  local action = ({ preview = 'arrestPreview', quote = 'arrestQuote', commit = 'arrestCommit' })[
    tostring(result.action or '')]
  if not action or not pending[action] then return end
  local response = type(result.response) == 'table' and result.response or { ok = false, code = 'invalid_response' }
  if action == 'arrestCommit' and response.ok == true then
    local chargeCount = type(response.chargeIds) == 'table' and #response.chargeIds or 0
    MZPoliceClient.SetPendingIntake({
      targetSource = tonumber(response.targetSource) or tonumber(activeContext and activeContext.targetSource),
      citizenid = response.target and response.target.citizenid or '',
      caseId = response.caseId or '',
      chargeId = chargeCount > 1 and '' or (response.chargeId or '')
    })
  end
  sendResult(action, response)
end)

RegisterNetEvent('mz_police:client:advanced:response', function(result)
  result = type(result) == 'table' and result or {}
  local action = tostring(result.action or '')
  local request = pending[action]
  if request and tostring(result.requestId or '') == request.id
    and (action == 'forensicAnalyze' or action == 'trackerSnapshot' or action == 'trackerBroadcast') then
    sendResult(action, result.response)
  end
end)

RegisterNetEvent('mz_dispatch:client:response', function(result)
  result = type(result) == 'table' and result or {}
  for mdtAction, dispatchAction in pairs(dispatchActions) do
    local request = pending[mdtAction]
    if request and dispatchAction == tostring(result.action or '')
      and tostring(result.requestId or '') == request.id then
      sendResult(mdtAction, result.response)
      return
    end
  end
end)

RegisterNetEvent('mz_police:client:dispatchPanicResult', function(result)
  result = type(result) == 'table' and result or {}
  local request = pending.dispatchPanic
  if not request or tostring(result.requestId or '') ~= request.id then return end
  sendResult('dispatchPanic', result.response)
end)

-- EVENTO DE NOVO CHAMADO: apenas invalida a fila do MDT. O toast e emitido uma
-- unica vez pelo server (mz_dispatch -> mz_notify). Reentregas do mesmo call_id
-- nao reabrem a notificacao nem disparam refresh extra.
RegisterNetEvent('mz_dispatch:client:newCall', function(call)
  call = type(call) == 'table' and call or {}
  local callId = tostring(call.public_id or '')
  if callId == '' then
    dispatchLog('new_call_ignored', nil, 'missing_call_id')
    return
  end
  if not rememberDispatchCall(callId) then
    dispatchLog('new_call_ignored', callId, 'duplicate_delivery')
    return
  end
  dispatchLog('new_call', callId, ('service=%s status=%s'):format(
    tostring(call.service_code or ''), tostring(call.status or '')))
  requestDispatchRefresh()
end)

-- Mudanca de status validada no servidor. Nao e notificacao: somente reconsulta
-- o snapshot canonico da fila para os MDTs abertos.
RegisterNetEvent('mz_dispatch:client:callUpdated', function(update)
  update = type(update) == 'table' and update or {}
  local callId = tostring(update.callId or update.public_id or '')
  if callId == '' then return end
  dispatchLog('call_updated', callId, 'status=' .. tostring(update.status or ''))
  requestDispatchRefresh()
end)

RegisterNUICallback('request', function(data, callback)
  data = type(data) == 'table' and data or {}
  local action = tostring(data.action or '')
  local requestId = tostring(data.requestId or '')
  local eventName = events[action]
  if not mdtOpen or #requestId < 8 or #requestId > 64
      or not requestId:match('^[%w:_-]+$') or type(data.payload) ~= 'table' then
    callback({ accepted = false, code = 'invalid_request' })
    return
  end
  if action == 'trackerSetView' then
    if MZPoliceClient.Tracker then
      MZPoliceClient.Tracker.SetMdtActive(data.payload.active == true)
    end
    callback({ accepted = true })
    SendNUIMessage({
      type = 'mdt:result',
      action = action,
      requestId = requestId,
      response = { ok = true, code = 'tracker_view_updated' }
    })
    return
  end
  if pending[action] then
    callback({ accepted = false, code = 'operation_busy' })
    return
  end

  requestSequence = requestSequence + 1
  pending[action] = { id = requestId, sequence = requestSequence }
  local sequence = requestSequence
  if action == 'prepareIntake' then
    local payload = data.payload
    local valid = tonumber(payload.targetSource) and tostring(payload.citizenid or ''):match('^[%w:_-]+$')
        and tostring(payload.caseId or ''):match('^[%w:_-]+$') and tostring(payload.chargeId or ''):match('^[%w:_-]+$')
    local response = valid and MZPoliceClient.SetPendingIntake(payload)
        and { ok = true, code = 'intake_prepared' } or { ok = false, code = 'invalid_intake_context' }
    pending[action] = nil
    callback({ accepted = true })
    SendNUIMessage({ type = 'mdt:result', action = action, requestId = requestId, response = response })
    return
  end
  if not eventName then
    pending[action] = nil
    callback({ accepted = false, code = 'invalid_request' })
    return
  end
  if eventName == 'mz_dispatch' then
    if GetResourceState('mz_dispatch') ~= 'started' then
      pending[action] = nil
      callback({ accepted = true })
      SendNUIMessage({
        type = 'mdt:result',
        action = action,
        requestId = requestId,
        response = { ok = false, code = 'dispatch_unavailable' }
      })
      return
    end
    local payload = data.payload
    local dispatchAction = dispatchActions[action]
    -- `list` e consulta de snapshot: o owner usa allowlist fechada e recusa
    -- payload.requestId. A chave de idempotencia pertence somente as mutacoes.
    if dispatchAction ~= 'list' then payload.requestId = requestId end
    TriggerServerEvent('mz_dispatch:server:request', {
      action = dispatchAction, requestId = requestId, payload = payload
    })
  elseif eventName == 'mz_police_advanced' then
    TriggerServerEvent('mz_police:server:advanced:request', {
      action = action, requestId = requestId, payload = data.payload
    })
  elseif eventName == 'mz_navigation' then
    local x, y, z = tonumber(data.payload.x), tonumber(data.payload.y), tonumber(data.payload.z)
    local response = { ok = false, code = 'invalid_coords' }
    if x and y and x == x and y == y and math.abs(x) <= 20000 and math.abs(y) <= 20000 then
      local coordinates = { x = x, y = y }
      if z and z == z and math.abs(z) <= 3000 then coordinates.z = z end
      local called, waypointOk, waypointError = pcall(function()
        return exports['mz_navigation']:SetWaypoint(coordinates)
      end)
      response = called and waypointOk == true
        and { ok = true, code = 'waypoint_set' }
        or { ok = false, code = tostring(waypointError or 'waypoint_failed') }
    end
    pending[action] = nil
    callback({ accepted = true })
    SendNUIMessage({
      type = 'mdt:result', action = action, requestId = requestId, response = response
    })
    return
  else
    if action == 'dispatchPanic' then data.payload.requestId = requestId end
    if action == 'arrestPreview' or action == 'arrestQuote' or action == 'arrestCommit' then
      data.payload.requestId = requestId
      data.payload.mode = 'processing'
    end
    TriggerServerEvent(eventName, data.payload)
  end
  callback({ accepted = true })

  CreateThread(function()
    Wait(15000)
    local request = pending[action]
    if not request or request.sequence ~= sequence then return end
    pending[action] = nil
    SendNUIMessage({
      type = 'mdt:result',
      action = action,
      requestId = requestId,
      response = { ok = false, code = 'request_timeout' }
    })
  end)
end)

RegisterNUICallback('close', function(_, callback)
  closeMdt()
  callback({ ok = true })
end)

local function openMdt(context)
  if mdtOpen then
    if context then
      activeContext = context
      SendNUIMessage({
        type = 'mdt:context',
        selectedCitizen = context.selectedCitizen,
        targetSource = context.targetSource,
        processing = context.processing
      })
    else
      closeMdt()
    end
    return
  end
  if opening then return end
  openingContext = context
  opening = true
  TriggerServerEvent('mz_police:server:records:listCases', { page = 1, pageSize = 25 })
  CreateThread(function()
    Wait(15000)
    if not opening then return end
    opening = false
    openingContext = nil
    notify('MDT indisponível: tempo de resposta excedido.', 'error')
  end)
end

function MZPoliceClient.OpenMdtCitizen(response)
  response = type(response) == 'table' and response or {}
  openMdt({
    selectedCitizen = { citizen = response.citizen or {}, police = response.police or {} },
    targetSource = tonumber(response.targetSource),
    processing = type(response.processing) == 'table' and response.processing or nil
  })
end

function MZPoliceClient.OpenMdt()
  openMdt(nil)
end

function MZPoliceClient.IsMdtOpen()
  return mdtOpen
end

RegisterCommand('mz_police_mdt', function()
  openMdt(nil)
end, false)

RegisterNetEvent('mz_core:client:playerLoaded', function()
  if MZPoliceClient.Tracker then MZPoliceClient.Tracker.Stop() end
  closeMdt()
end)

RegisterNetEvent('mz_core:client:characterSelectionRequired', function()
  if MZPoliceClient.Tracker then MZPoliceClient.Tracker.Stop() end
  closeMdt()
end)

AddEventHandler('onClientResourceStop', function(resourceName)
  if resourceName ~= GetCurrentResourceName() then return end
  if MZPoliceClient.Tracker then MZPoliceClient.Tracker.Stop() end
  pending = {}
  SetNuiFocus(false, false)
end)
