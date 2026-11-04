MZPolice = MZPolice or {}

local function dependencyStarted(resourceName)
  return GetResourceState(resourceName) == 'started'
end

local function initialize()
  if not dependencyStarted('mz_core') or not dependencyStarted('mz_org') then
    print('[mz_police][init] initialization blocked: canonical dependency unavailable')
    return false
  end

  local bootstrap = type(MZPolice.RecordsPrepare.bootstrap) == 'function'
    and MZPolice.RecordsPrepare.bootstrap
    or MZPolice.RecordsPrepare.run
  local recordsReady, recordsError = bootstrap()
  if recordsReady ~= true then
    print(('[mz_police][records] initialization blocked: %s'):format(tostring(recordsError)))
  end
  local organizationReady = MZPolice.Bridge.organizationReady() == true
  MZPolice.Audit.started(organizationReady)
  if MZPolice.Custody then MZPolice.Custody.start() end
  if MZPolice.Restraints then MZPolice.Restraints.start() end
  if MZPolice.Restraints and type(CreateThread) == 'function' and type(GetPlayers) == 'function' then
    CreateThread(function()
      Wait(2000)
      for _, rawSource in ipairs(GetPlayers() or {}) do
        local source = tonumber(rawSource)
        if source then MZPolice.Restraints.onPlayerLoaded(source) end
      end
    end)
  end
  local prisonConfig = type(MZPoliceConfig.Prison) == 'table' and MZPoliceConfig.Prison or {}
  if prisonConfig.processingEnabled ~= true or type(prisonConfig.processingPoints) ~= 'table'
    or next(prisonConfig.processingPoints) == nil then
    print('[mz_police][processing] disabled: configure validated processingPoints before activation')
  end
  local dutyConfigured
  if organizationReady then
    local policeOrg = MZPolice.Bridge.getOrganizationByCode('police')
    local dutyPoint = policeOrg and type(policeOrg.config) == 'table' and policeOrg.config.dutyPoint or nil
    dutyConfigured = type(dutyPoint) == 'table' and dutyPoint.enabled == true
    if not dutyConfigured then
      print('[mz_police][init] police dutyPoint is not configured/enabled; officers cannot enter duty until mz_org config is updated')
    end
  end
  print(('[mz_police][init] initialized; organization_ready=%s records_ready=%s stations=%s duty_point=%s'):format(
    tostring(organizationReady),
    tostring(recordsReady == true),
    tostring(MZPolice.Stations and MZPolice.Stations.configuredCount() or 0),
    tostring(dutyConfigured)
  ))
  return true
end

AddEventHandler('onResourceStart', function(resourceName)
  if resourceName ~= GetCurrentResourceName() then return end
  if type(CreateThread) == 'function' then
    CreateThread(function() initialize() end)
  else
    initialize()
  end
end)

RegisterNetEvent('mz_police:server:heli:spotlight', function(active)
  local actorSource = tonumber(source)
  if not actorSource or not MZPolice.Advanced or type(MZPolice.Advanced.spotlight) ~= 'function' then return end
  local ok, code = MZPolice.Advanced.spotlight(actorSource, active)
  if ok ~= true then
    TriggerClientEvent('mz_police:client:heli:notice', actorSource, tostring(code or 'spotlight_unavailable'))
  end
end)

AddEventHandler('playerDropped', function()
  MZPolice.Audit.clearSource(source)
  if MZPolice.Restraints then MZPolice.Restraints.cleanupSource(source, 'player_dropped') end
  if MZPolice.Custody then MZPolice.Custody.cleanupSource(source, 'player_dropped') end
  if MZPolice.Search then MZPolice.Search.cleanupSource(source) end
  if MZPolice.Stations then MZPolice.Stations.cleanupSource(source) end
  if MZPolice.Enforcement then MZPolice.Enforcement.cleanupSource(source, 'player_dropped') end
  if MZPolice.Evidence then MZPolice.Evidence.cleanupSource(source) end
  if MZPolice.Records then MZPolice.Records.cleanupSource(source) end
  if MZPolice.Prison then MZPolice.Prison.cleanupSource(source) end
  if MZPolice.Arrest then MZPolice.Arrest.cleanupSource(source) end
  if MZPolice.Interactions then MZPolice.Interactions.cleanupSource(source) end
  if MZPolice.Advanced then MZPolice.Advanced.cleanupSource(source) end
end)

AddEventHandler('onResourceStop', function(resourceName)
  if resourceName ~= GetCurrentResourceName() or not MZPolice.Custody then return end
  if MZPolice.Search then MZPolice.Search.stop() end
  if MZPolice.Enforcement then MZPolice.Enforcement.stop() end
  if MZPolice.Evidence then MZPolice.Evidence.stop() end
  if MZPolice.Records then MZPolice.Records.stop() end
  if MZPolice.Prison then MZPolice.Prison.stop() end
  if MZPolice.Arrest then MZPolice.Arrest.stop() end
  if MZPolice.Interactions then MZPolice.Interactions.stop() end
  if MZPolice.Advanced then MZPolice.Advanced.stop() end
  if MZPolice.Restraints then MZPolice.Restraints.stop('resource_stop') end
  MZPolice.Custody.stop('resource_stop')
end)

MZPolice.Initialize = initialize

-- Reconciliacao de algemas fisicas persistidas quando o personagem carrega.
AddEventHandler('mz_core:server:playerLoaded', function(source)
  if MZPolice.Restraints then
    MZPolice.Restraints.onPlayerLoaded(tonumber(source))
  end
end)
