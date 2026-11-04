-- Adaptador de radial do mz_police. Apresentacao apenas; autorizacao e
-- operacoes continuam em client/interactions.lua e no servidor do mz_police.

local handle
local retryScheduled = false
local registerGeneration = 0

local function interactions()
  local value = MZPoliceClient.Interactions
  return type(value) == 'table' and value or nil
end

local function accessOk()
  local value = interactions()
  return value ~= nil and value.accessOk() == true
end

local function notify(message, kind)
  local value = interactions()
  if value and type(value.notify) == 'function' then
    value.notify(message, kind)
  end
end

local function registerRadial()
  if GetResourceState('mz_radialmenu') ~= 'started' then return end
  if not interactions() then return end

  if handle then
    pcall(function() exports['mz_radialmenu']:RemoveOption(handle) end)
    handle = nil
  end

  local children = {
    {
      id = 'open_mdt', label = 'Abrir MDT', icon = 'tablet-smartphone',
      canOpen = accessOk,
      onSelect = function()
        if not accessOk() or type(MZPoliceClient.OpenMdt) ~= 'function' then return false end
        MZPoliceClient.OpenMdt()
        return true
      end
    },
    {
      id = 'select_citizen', label = 'Selecionar cidadão', icon = 'scan-face',
      description = 'Aponte explicitamente pelo target.',
      canOpen = function()
        return accessOk() and GetResourceState('mz_target') == 'started'
      end,
      onSelect = function()
        if not accessOk() or GetResourceState('mz_target') ~= 'started' then return false end
        local ok, started = pcall(function() return exports['mz_target']:StartTargeting() end)
        if ok and started == true then
          notify('Aponte para o cidadão e abra Ações policiais.', 'inform')
        end
        return ok and started == true
      end
    }
  }

  children[#children + 1] = {
    id = 'enforcement', label = 'Fiscalização', icon = 'gauge',
    canOpen = function()
      return accessOk() and type(MZPoliceClient.OpenEnforcement) == 'function'
    end,
    onSelect = function()
      if not accessOk() or type(MZPoliceClient.OpenEnforcement) ~= 'function' then return false end
      MZPoliceClient.OpenEnforcement()
      return true
    end
  }

  if type(MZPoliceConfig.Advanced) == 'table' and MZPoliceConfig.Advanced.enabled == true then
    children[#children + 1] = {
      id = 'advanced', label = 'Sistemas policiais', icon = 'badge',
      canOpen = function()
        return accessOk() and type(MZPoliceClient.OpenAdvanced) == 'function'
      end,
      onSelect = function()
        if not accessOk() or type(MZPoliceClient.OpenAdvanced) ~= 'function' then return false end
        MZPoliceClient.OpenAdvanced()
        return true
      end
    }
  end

  local heli = MZPoliceClient.Heli
  if type(heli) == 'table' then
    children[#children + 1] = {
      id = 'helicopter', label = 'Helicóptero', icon = 'helicopter',
      canOpen = function()
        return accessOk() and type(heli.IsInHeli) == 'function' and heli.IsInHeli() == true
      end,
      children = {
        {
          id = 'heli_camera', label = 'Câmera aérea (FLIR)', icon = 'camera',
          description = 'Abre ou fecha a câmera do helicóptero autorizado.',
          canOpen = function()
            return accessOk() and type(heli.IsInHeli) == 'function' and heli.IsInHeli() == true
          end,
          onSelect = function()
            if not accessOk() or type(heli.ToggleCamera) ~= 'function' then return false end
            return heli.ToggleCamera() == true
          end
        },
        {
          id = 'heli_vision', label = 'Alternar visão', icon = 'eye',
          description = 'Normal, visão noturna e térmica.',
          canOpen = function()
            return accessOk() and type(heli.IsActive) == 'function' and heli.IsActive() == true
          end,
          onSelect = function()
            if not accessOk() or type(heli.CycleVision) ~= 'function' then return false end
            return heli.CycleVision() == true
          end
        },
        {
          id = 'heli_spotlight', label = 'Alternar refletor', icon = 'flashlight',
          description = 'Refletor de busca sincronizado com a tripulação.',
          canOpen = function()
            return accessOk() and type(heli.IsInHeli) == 'function' and heli.IsInHeli() == true
          end,
          onSelect = function()
            if not accessOk() or type(heli.ToggleSpotlight) ~= 'function' then return false end
            return heli.ToggleSpotlight() == true
          end
        },
        {
          id = 'heli_rappel', label = 'Rapel', icon = 'arrow-down-to-line',
          description = 'Desce pelo cabo nos assentos laterais.',
          canOpen = function()
            return accessOk() and type(heli.IsInHeli) == 'function' and heli.IsInHeli() == true
          end,
          onSelect = function()
            if not accessOk() or type(heli.Rappel) ~= 'function' then return false end
            return heli.Rappel() == true
          end
        }
      }
    }
  end

  local callOk, ok, registeredHandle = pcall(function()
    return exports['mz_radialmenu']:RegisterOption({
      id = 'police_actions', label = 'Polícia', icon = 'shield',
      canOpen = accessOk,
      children = children
    })
  end)

  if callOk and ok == true then
    handle = registeredHandle
    print(('[mz_police][radial] registered handle=%s'):format(tostring(handle)))
    return
  end

  print(('[mz_police][radial] register failed: %s'):format(tostring(callOk and registeredHandle or ok)))
  if not retryScheduled then
    retryScheduled = true
    CreateThread(function()
      Wait(1000)
      retryScheduled = false
      registerRadial()
    end)
  end
end

local function unregisterRadial()
  registerGeneration = registerGeneration + 1
  if handle and GetResourceState('mz_radialmenu') == 'started' then
    pcall(function() exports['mz_radialmenu']:RemoveOption(handle) end)
  end
  handle = nil
end

local function requestRegister(delay)
  registerGeneration = registerGeneration + 1
  local generation = registerGeneration

  CreateThread(function()
    Wait(delay or 500)
    if generation == registerGeneration then
      registerRadial()
    end
  end)
end

MZPoliceClient.RadialIntegration = {
  Register = registerRadial,
  Unregister = unregisterRadial,
  GetStatus = function()
    return { handle = handle }
  end
}

requestRegister(1000)

AddEventHandler('onClientResourceStart', function(resourceName)
  if resourceName == 'mz_radialmenu' or resourceName == GetCurrentResourceName() then
    requestRegister(500)
  end
end)

AddEventHandler('mz_radialmenu:client:ready', registerRadial)

AddEventHandler('onClientResourceStop', function(resourceName)
  if resourceName == 'mz_radialmenu' then
    handle = nil
    return
  end

  if resourceName == GetCurrentResourceName() then
    unregisterRadial()
  end
end)
