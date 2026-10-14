MZPolice = MZPolice or {}

local function dependencyStarted(resourceName)
  return GetResourceState(resourceName) == 'started'
end

local function initialize()
  if not dependencyStarted('mz_core') or not dependencyStarted('mz_org') then
    print('[mz_police][P1] initialization blocked: canonical dependency unavailable')
    return false
  end

  local recordsReady, recordsError = MZPolice.RecordsPrepare.run()
  if recordsReady ~= true then
    print(('[mz_police][P6] records initialization blocked: %s'):format(tostring(recordsError)))
  end
  local organizationReady = MZPolice.Bridge.organizationReady() == true
  MZPolice.Audit.started(organizationReady)
  if MZPolice.Custody then MZPolice.Custody.start() end
  print(('[mz_police][P6] initialized; organization_ready=%s records_ready=%s stations=%s'):format(
    tostring(organizationReady),
    tostring(recordsReady == true),
    tostring(MZPolice.Stations and MZPolice.Stations.configuredCount() or 0)
  ))
  return true
end

AddEventHandler('onResourceStart', function(resourceName)
  if resourceName ~= GetCurrentResourceName() then return end
  initialize()
end)

AddEventHandler('playerDropped', function()
  MZPolice.Audit.clearSource(source)
  if MZPolice.Custody then MZPolice.Custody.cleanupSource(source, 'player_dropped') end
  if MZPolice.Search then MZPolice.Search.cleanupSource(source) end
  if MZPolice.Stations then MZPolice.Stations.cleanupSource(source) end
  if MZPolice.Enforcement then MZPolice.Enforcement.cleanupSource(source, 'player_dropped') end
  if MZPolice.Evidence then MZPolice.Evidence.cleanupSource(source) end
  if MZPolice.Records then MZPolice.Records.cleanupSource(source) end
end)

AddEventHandler('onResourceStop', function(resourceName)
  if resourceName ~= GetCurrentResourceName() or not MZPolice.Custody then return end
  if MZPolice.Search then MZPolice.Search.stop() end
  if MZPolice.Enforcement then MZPolice.Enforcement.stop() end
  if MZPolice.Records then MZPolice.Records.stop() end
  MZPolice.Custody.stop('resource_stop')
end)

MZPolice.Initialize = initialize
