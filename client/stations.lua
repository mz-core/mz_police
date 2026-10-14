local registeredPoints = {}
local requestSequence = 0

local function nextRequestId(action)
  requestSequence = requestSequence + 1
  return ('armory:%s:%s:%s'):format(action, GetGameTimer(), requestSequence)
end

local function notify(message, kind)
  if GetResourceState('mz_menu') == 'started' then
    exports['mz_menu']:Notify(message, kind or 'inform')
  else
    print(('[mz_police] %s'):format(tostring(message)))
  end
end

local function unregisterPoints()
  if GetResourceState('mz_interact') == 'started' then
    exports['mz_interact']:RemovePointsByOwner()
  end
  registeredPoints = {}
end

local function registerPoints()
  unregisterPoints()
  if GetResourceState('mz_interact') ~= 'started' then return end
  for stationId, station in pairs(MZPoliceConfig.Stations or {}) do
    local armory = type(station) == 'table' and station.armory or nil
    if station.enabled ~= false and type(armory) == 'table' and armory.enabled ~= false and armory.coords then
      local pointId = ('mz_police:armory:%s'):format(stationId)
      local ok = exports['mz_interact']:AddPoint({
        id = pointId,
        coords = armory.coords,
        drawDistance = tonumber(armory.drawDistance) or 15.0,
        interactDistance = tonumber(armory.interactDistance) or 2.5,
        marker = type(armory.marker) == 'table' and armory.marker or { enabled = true, type = 1 },
        blip = type(armory.blip) == 'table' and armory.blip or { enabled = false },
        text = { enabled = true, label = tostring(armory.label or '[E] Arsenal policial') },
        event = { type = 'server', name = 'mz_police:server:armory:open', args = { { stationId = stationId } } }
      })
      if ok == true then registeredPoints[pointId] = true end
    end
  end
end

local function openArmory(response)
  local options = {}
  for _, entry in ipairs(response.catalog or {}) do
    options[#options + 1] = {
      title = ('Retirar: %s'):format(entry.label),
      description = ('Item rastreado • cargo mínimo %s'):format(entry.minimumGrade),
      icon = 'shield',
      onSelect = function()
        TriggerServerEvent('mz_police:server:armory:issue', {
          stationId = response.station.id,
          catalogKey = entry.key,
          requestId = nextRequestId('issue')
        })
      end
    }
  end
  for _, entry in ipairs(response.issued or {}) do
    options[#options + 1] = {
      title = ('Devolver: %s'):format(entry.label),
      description = ('UID %s'):format(entry.instanceUid),
      icon = 'rotate-left',
      onSelect = function()
        TriggerServerEvent('mz_police:server:armory:return', {
          stationId = response.station.id,
          instanceUid = entry.instanceUid,
          requestId = nextRequestId('return')
        })
      end
    }
  end
  if #options == 0 then
    options[1] = { title = 'Nenhum equipamento disponível', readOnly = true, icon = 'info' }
  end
  exports['mz_menu']:OpenContext({
    id = ('mz_police:armory:%s'):format(response.station.id),
    title = response.station.label,
    subtitle = 'Arsenal policial rastreado',
    brand = 'MZ Police',
    headerIcon = 'shield',
    options = options
  })
end

RegisterNetEvent('mz_police:client:armory:result', function(response)
  response = type(response) == 'table' and response or { ok = false, code = 'invalid_response' }
  if response.ok ~= true then
    notify(('Operação do arsenal negada: %s'):format(tostring(response.code or 'unknown')), 'error')
    return
  end
  if response.action == 'open' then
    if GetResourceState('mz_menu') ~= 'started' then
      notify('mz_menu indisponível.', 'error')
      return
    end
    openArmory(response)
    return
  end
  notify(response.action == 'return' and 'Equipamento devolvido.' or 'Equipamento emitido.', 'success')
end)

CreateThread(function()
  Wait(1000)
  registerPoints()
end)

AddEventHandler('onClientResourceStart', function(resourceName)
  if resourceName == 'mz_interact' or resourceName == GetCurrentResourceName() then
    Wait(500)
    registerPoints()
  end
end)

AddEventHandler('onClientResourceStop', function(resourceName)
  if resourceName == GetCurrentResourceName() then unregisterPoints() end
end)
