MZPolice = MZPolice or {}

local active = {}
local sequence = 0

local function enabled()
  return MZPoliceConfig.Search.thirdPartyInventoryEnabled == true
end

local function failure(code)
  return { ok = false, error = { code = tostring(code or 'access_denied') } }
end

local function inventoryExport(name, ...)
  local args = { ... }
  local ok, allowed, value = pcall(function()
    return exports['mz_inventory'][name](exports['mz_inventory'], table.unpack(args))
  end)
  if not ok then return false, 'inventory_unavailable' end
  return allowed, value
end

local function close(actorSource, notifyClient)
  local session = active[actorSource]
  if not session then return end
  active[actorSource] = nil
  inventoryExport('RevokeThirdPartyInventoryReadSession', actorSource, session.token)
  if session.searchId then MZPolice.Search.closeOwned(actorSource, session.searchId) end
  if notifyClient then TriggerClientEvent('mz_inventory:client:thirdPartyClosed', actorSource, session.id) end
end

local function current(actorSource, id)
  if not enabled() then return nil, 'integration_disabled' end
  local session = active[actorSource]
  if not session or session.id ~= tostring(id or '') then return nil, 'session_not_found' end
  if os.time() >= session.expiresAt then close(actorSource, true); return nil, 'session_expired' end
  return session
end

local function view(actorSource, session)
  local readOk, read = inventoryExport('GetThirdPartyInventoryReadSnapshot', actorSource, session.token)
  if not readOk then close(actorSource, true); return failure(read) end
  local viewCallOk, actorView = pcall(function()
    return exports['mz_inventory']:GetInventoryViewSnapshot(actorSource, { player = { type = 'player' } })
  end)
  if not viewCallOk or type(actorView) ~= 'table' or actorView.ok ~= true then
    close(actorSource, true)
    return type(actorView) == 'table' and actorView or failure('inventory_unavailable')
  end
  local targetInventory = read.inventory
  if session.searchId then
    local granted, grantedInventory = MZPolice.Search.snapshot(actorSource, session.searchId)
    if not granted then close(actorSource, true); return failure(grantedInventory) end
    targetInventory = grantedInventory
  end
  local canSeize = false
  if session.searchId then
    local decision = MZPolice.Policy.authorize(actorSource, 'police.seize')
    canSeize = decision.ok == true
  end
  local data = actorView.data
  data.target = targetInventory.main
  data.targetEquipment = targetInventory.equipment
  data.thirdParty = {
    id = session.id, mode = session.mode, canSeize = canSeize,
    expiresInMs = math.max(0, (session.expiresAt - os.time()) * 1000)
  }
  return { ok = true, data = data }
end

local function open(actorSource, targetSource, mode)
  if not enabled() then return failure('integration_disabled') end
  targetSource = tonumber(targetSource)
  if not targetSource or targetSource <= 0 or targetSource == actorSource then return failure('invalid_target') end
  close(actorSource, false)
  local readOk, read = inventoryExport('CreateThirdPartyInventoryReadSession', actorSource, targetSource, mode)
  if not readOk then return failure(read) end
  local searchId, canSeize
  if mode == 'police_search' then
    sequence = sequence + 1
    searchId = ('search:%s:%s:%s'):format(actorSource, os.time(), sequence)
    local search = MZPolice.Search.open(actorSource, { targetSource = targetSource, requestId = searchId })
    if search.ok ~= true then
      inventoryExport('RevokeThirdPartyInventoryReadSession', actorSource, read.token)
      return failure(search.code)
    end
    canSeize = search.canSeize == true
  end
  sequence = sequence + 1
  local id = ('interaction:%x:%x:%x'):format(os.time(), math.random(0, 0x7fffffff), sequence)
  active[actorSource] = {
    id = id, token = read.token, mode = mode, searchId = searchId,
    targetSource = targetSource, expiresAt = tonumber(read.expiresAt) or os.time()
  }
  TriggerClientEvent('mz_inventory:client:openThirdParty', actorSource, {
    id = id, mode = mode, canSeize = canSeize == true,
    expiresInMs = math.max(0, (active[actorSource].expiresAt - os.time()) * 1000)
  })
  return { ok = true }
end

RegisterNetEvent('mz_police:server:thirdParty:openCivil', function(payload)
  local response = open(source, type(payload) == 'table' and payload.targetSource, 'civil_robbery')
  if response.ok ~= true then TriggerClientEvent('mz_inventory:client:thirdPartyDenied', source, response.error.code) end
end)

RegisterNetEvent('mz_police:server:thirdParty:openPolice', function(payload)
  local response = open(source, type(payload) == 'table' and payload.targetSource, 'police_search')
  if response.ok ~= true then TriggerClientEvent('mz_inventory:client:thirdPartyDenied', source, response.error.code) end
end)

lib.callback.register('mz_police:server:thirdParty:view', function(actorSource, id)
  local session, err = current(actorSource, id)
  if not session then return failure(err) end
  return view(actorSource, session)
end)

lib.callback.register('mz_police:server:thirdParty:status', function(actorSource, id)
  local session, err = current(actorSource, id)
  if not session then return failure(err) end
  local ok, value = inventoryExport('GetThirdPartyInventoryReadSnapshot', actorSource, session.token)
  if not ok then close(actorSource, true); return failure(value) end
  return { ok = true, data = { expiresInMs = math.max(0, (session.expiresAt - os.time()) * 1000) } }
end)

lib.callback.register('mz_police:server:thirdParty:transfer', function(actorSource, request)
  request = type(request) == 'table' and request or {}
  local session, err = current(actorSource, request.id)
  if not session then return failure(err) end
  if session.mode ~= 'civil_robbery' then return failure('session_mode_denied') end
  local ok, result = inventoryExport('TransferThirdPartyInventoryItem', actorSource,
    session.token, request.fromSlot, request.amount, request.toSlot)
  if not ok then return failure(result) end
  local response = view(actorSource, session)
  if response.ok then response.data.transfer = result.transfer end
  return response
end)

lib.callback.register('mz_police:server:thirdParty:seize', function(actorSource, request)
  request = type(request) == 'table' and request or {}
  local session, err = current(actorSource, request.id)
  if not session then return failure(err) end
  if session.mode ~= 'police_search' or not session.searchId then return failure('session_mode_denied') end
  local readOk, read = inventoryExport('GetThirdPartyInventoryReadSnapshot', actorSource, session.token)
  if not readOk then close(actorSource, true); return failure(read) end
  local granted, inventory = MZPolice.Search.snapshot(actorSource, session.searchId)
  if not granted then close(actorSource, true); return failure(inventory) end
  local fromSlot = tonumber(request.fromSlot)
  local amount = tonumber(request.amount)
  if not fromSlot or fromSlot % 1 ~= 0 or not amount or amount % 1 ~= 0 then return failure('invalid_payload') end
  if request.section ~= nil and request.section ~= 'main' and request.section ~= 'equipment' then
    return failure('invalid_payload')
  end
  local section = request.section or 'main'
  local row
  for _, slot in ipairs(type(inventory[section]) == 'table' and inventory[section].slots or {}) do
    if tonumber(slot.slot) == fromSlot and slot.occupied == true then row = slot; break end
  end
  if not row then return failure('source_slot_empty') end
  local uid = tostring(row.stack_locator or row.instance_uid or '')
  if uid == '' then return failure('invalid_instance_uid') end
  sequence = sequence + 1
  local seized = MZPolice.Search.seize(actorSource, {
    searchId = session.searchId, instanceUid = uid, amount = amount,
    operationId = ('seize:%s:%s:%s'):format(actorSource, os.time(), sequence),
    containerId = MZPoliceConfig.Search.defaultEvidenceContainer
  })
  if seized.ok ~= true then return failure(seized.code) end
  local response = view(actorSource, session)
  if response.ok then response.data.seizure = seized.transfer end
  return response
end)

RegisterNetEvent('mz_police:server:thirdParty:close', function(id)
  if active[source] and active[source].id == tostring(id or '') then close(source, false) end
end)

AddEventHandler('playerDropped', function()
  local dropped = source
  close(dropped, false)
  for actorSource, session in pairs(active) do
    if session.targetSource == dropped then close(actorSource, true) end
  end
end)

AddEventHandler('onResourceStop', function(resourceName)
  if resourceName ~= GetCurrentResourceName() and resourceName ~= 'mz_inventory' then return end
  for actorSource in pairs(active) do close(actorSource, resourceName == 'mz_inventory') end
end)
