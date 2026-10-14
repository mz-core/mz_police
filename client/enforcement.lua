local requestSequence = 0
local lastScan

local function requestId(action)
  requestSequence = requestSequence + 1
  return ('enforcement:%s:%s:%s'):format(action, GetGameTimer(), requestSequence)
end

local function notify(message, kind)
  if GetResourceState('mz_menu') == 'started' then
    exports['mz_menu']:Notify(message, kind or 'inform')
  else
    print(('[mz_police] %s'):format(tostring(message)))
  end
end

local function requestScan(mode)
  TriggerServerEvent('mz_police:server:enforcement:scan', { mode = mode, requestId = requestId(mode) })
end

local function openTools()
  local options = {
    { title = 'ANPR — veículo mais próximo', icon = 'car', onSelect = function() requestScan('anpr') end },
    { title = 'Radar — veículo mais próximo', icon = 'gauge', onSelect = function() requestScan('radar') end }
  }
  for objectType, config in pairs(MZPoliceConfig.RoadObjects.types or {}) do
    if type(config) == 'table' and config.enabled ~= false then
      options[#options + 1] = {
        title = ('Posicionar: %s'):format(tostring(config.label or objectType)), icon = 'triangle-exclamation',
        onSelect = function()
          TriggerServerEvent('mz_police:server:road:place', {
            objectType = objectType, requestId = requestId('road-place')
          })
        end
      }
    end
  end
  options[#options + 1] = {
    title = 'Remover objeto viário próximo', icon = 'trash',
    onSelect = function()
      TriggerServerEvent('mz_police:server:road:removeNearest', { requestId = requestId('road-remove') })
    end
  }
  exports['mz_menu']:OpenContext({
    id = 'mz_police:enforcement', title = 'Fiscalização', subtitle = 'Operações server-authoritative',
    brand = 'MZ Police', headerIcon = 'shield', options = options
  })
end

local function openScan(response)
  lastScan = response.vehicle
  local vehicle = response.vehicle
  local options = {
    {
      title = ('Placa %s'):format(vehicle.plate),
      description = ('Modelo %s • estado %s • %.1f km/h'):format(vehicle.model, vehicle.state, vehicle.speedKph),
      readOnly = true, icon = 'car'
    }
  }
  for _, flag in ipairs(vehicle.flags or {}) do
    options[#options + 1] = {
      title = ('Flag ativa: %s'):format(flag.code), description = flag.reference, readOnly = true, icon = 'flag'
    }
  end
  for _, option in ipairs(response.flagOptions or {}) do
    options[#options + 1] = {
      title = ('Marcar: %s'):format(option.label), icon = 'flag',
      onSelect = function()
        TriggerServerEvent('mz_police:server:enforcement:flag', {
          scanId = vehicle.scanId, flagCode = option.key, active = true, reference = '', requestId = requestId('flag')
        })
      end
    }
  end
  for _, option in ipairs(response.impoundReasons or {}) do
    options[#options + 1] = {
      title = ('Apreender: %s'):format(option.label), icon = 'truck', destructive = true,
      onSelect = function()
        TriggerServerEvent('mz_police:server:enforcement:impound', {
          scanId = vehicle.scanId, reasonCode = option.key, reference = '', requestId = requestId('impound')
        })
      end
    }
  end
  exports['mz_menu']:OpenContext({
    id = 'mz_police:enforcement:scan', title = response.mode == 'radar' and 'Radar' or 'ANPR',
    subtitle = 'Leitura validada no servidor', brand = 'MZ Police', headerIcon = 'car', options = options
  })
end

RegisterNetEvent('mz_police:client:enforcement:result', function(response)
  response = type(response) == 'table' and response or { ok = false, code = 'invalid_response' }
  if response.ok ~= true then
    notify(('Fiscalização negada: %s'):format(tostring(response.code or 'unknown')), 'error')
    return
  end
  if response.action == 'scan' then openScan(response); return end
  notify(tostring(response.code or 'Operação concluída.'), 'success')
end)

RegisterCommand('mz_police_tools', function()
  if GetResourceState('mz_menu') ~= 'started' then notify('mz_menu indisponível.', 'error'); return end
  openTools()
end, false)
