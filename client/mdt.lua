local mdtOpen = false
local opening = false
local requestSequence = 0
local pending = {}

local events = {
  searchCitizens = 'mz_police:server:records:searchCitizens',
  getCitizen = 'mz_police:server:records:getCitizen',
  upsertRecord = 'mz_police:server:records:upsertRecord',
  createCase = 'mz_police:server:records:createCase',
  listCases = 'mz_police:server:records:listCases',
  getCase = 'mz_police:server:records:getCase',
  updateCase = 'mz_police:server:records:updateCase',
  addCasePerson = 'mz_police:server:records:addCasePerson',
  evidenceList = 'mz_police:server:evidence:list'
}

local function notify(message, kind)
  if GetResourceState('mz_menu') == 'started' then
    exports['mz_menu']:Notify(message, kind or 'inform')
  else
    print(('[mz_police] %s'):format(tostring(message)))
  end
end

local function closeMdt()
  if not mdtOpen then return end
  mdtOpen = false
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
    mdtOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ type = 'mdt:open', bootstrap = response })
    return
  end

  sendResult(action, response)
end)

RegisterNetEvent('mz_police:client:evidence:result', function(response)
  sendResult('evidenceList', response)
end)

RegisterNUICallback('request', function(data, callback)
  data = type(data) == 'table' and data or {}
  local action = tostring(data.action or '')
  local requestId = tostring(data.requestId or '')
  local eventName = events[action]
  if not mdtOpen or not eventName or #requestId < 8 or #requestId > 64
    or not requestId:match('^[%w:_-]+$') or type(data.payload) ~= 'table' then
    callback({ accepted = false, code = 'invalid_request' })
    return
  end
  if pending[action] then
    callback({ accepted = false, code = 'operation_busy' })
    return
  end

  requestSequence = requestSequence + 1
  pending[action] = { id = requestId, sequence = requestSequence }
  local sequence = requestSequence
  TriggerServerEvent(eventName, data.payload)
  callback({ accepted = true })

  CreateThread(function()
    Wait(15000)
    local request = pending[action]
    if not request or request.sequence ~= sequence then return end
    pending[action] = nil
    SendNUIMessage({
      type = 'mdt:result', action = action, requestId = requestId,
      response = { ok = false, code = 'request_timeout' }
    })
  end)
end)

RegisterNUICallback('close', function(_, callback)
  closeMdt()
  callback({ ok = true })
end)

RegisterCommand('mz_police_mdt', function()
  if mdtOpen then closeMdt(); return end
  if opening then return end
  opening = true
  TriggerServerEvent('mz_police:server:records:listCases', { page = 1, pageSize = 25 })
  CreateThread(function()
    Wait(15000)
    if not opening then return end
    opening = false
    notify('MDT indisponível: tempo de resposta excedido.', 'error')
  end)
end, false)

AddEventHandler('onClientResourceStop', function(resourceName)
  if resourceName ~= GetCurrentResourceName() then return end
  SetNuiFocus(false, false)
end)
