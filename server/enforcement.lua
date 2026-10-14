MZPolice = MZPolice or {}

local Enforcement = {}
local rateLimits = {}
local terminals = {}
local objects = {}
local objectSequence = 0

local SCAN_KEYS = { mode = true, requestId = true }
local FLAG_KEYS = { scanId = true, flagCode = true, active = true, reference = true, requestId = true }
local IMPOUND_KEYS = { scanId = true, reasonCode = true, reference = true, requestId = true }
local PLACE_KEYS = { objectType = true, requestId = true }
local REMOVE_KEYS = { requestId = true }

local function copy(value)
  if type(value) ~= 'table' then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = copy(item) end
  return out
end

local function trim(value)
  return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function key(value, maximum)
  value = trim(value):lower()
  if #value < 2 or #value > maximum or not value:match('^[a-z0-9_-]+$') then return nil end
  return value
end

local function closed(payload, allowed)
  if type(payload) ~= 'table' then return false end
  for field in pairs(payload) do if not allowed[field] then return false end end
  return true
end

local function rateAllowed(source)
  local config = MZPoliceConfig.Enforcement.rateLimit or {}
  local now = GetGameTimer()
  local windowMs = math.max(1000, tonumber(config.windowMs) or 5000)
  local maximum = math.max(1, math.floor(tonumber(config.maximum) or 8))
  local window = rateLimits[source]
  if not window or now - window.startedAt >= windowMs then
    rateLimits[source] = { startedAt = now, count = 1 }
    return true
  end
  window.count = window.count + 1
  return window.count <= maximum
end

local function authorize(source, capability)
  local decision = MZPolice.Policy.authorize(source, capability)
  return decision.ok == true and decision or nil, decision.code
end

local function replay(source, requestId, fingerprint, execute)
  requestId = trim(requestId)
  if #requestId < 8 or #requestId > 96 or not requestId:match('^[%w:_-]+$') then
    return { ok = false, code = 'invalid_request_id' }
  end
  local bucket = terminals[source] or {}
  terminals[source] = bucket
  local existing = bucket[requestId]
  if existing then
    if existing.fingerprint ~= fingerprint then return { ok = false, code = 'request_id_conflict' } end
    return copy(existing.response)
  end
  local ok, response = pcall(execute, requestId)
  if not ok then response = { ok = false, code = 'operation_failed' } end
  bucket[requestId] = { fingerprint = fingerprint, response = copy(response), createdAt = GetGameTimer() }
  return response
end

local function configuredOptions(config)
  local out = {}
  for optionKey, option in pairs(type(config) == 'table' and config or {}) do
    local normalizedKey = key(optionKey, 48)
    if normalizedKey and type(option) == 'table' and option.enabled ~= false then
      out[#out + 1] = { key = normalizedKey, label = trim(option.label):sub(1, 64) }
    end
  end
  table.sort(out, function(left, right) return left.key < right.key end)
  return out
end

function Enforcement.scan(source, payload)
  if not closed(payload, SCAN_KEYS) then return { ok = false, code = 'invalid_payload' } end
  if not rateAllowed(source) then return { ok = false, code = 'rate_limited' } end
  local mode = trim(payload.mode):lower()
  local capability = mode == 'radar' and 'police.radar' or mode == 'anpr' and 'police.anpr' or nil
  if not capability then return { ok = false, code = 'invalid_scan_mode' } end
  local decision, authErr = authorize(source, capability)
  if not decision then return { ok = false, code = authErr } end
  local result, scanErr = MZPolice.Bridge.scanNearestVehicle(source, MZPoliceConfig.Enforcement.scanDistance)
  MZPolice.Audit.enforcement('scan', decision.identity, {
    orgCode = decision.organization.code, plate = result and result.plate, mode = mode,
    result = result and 'scanned' or 'denied', reason = scanErr
  })
  if not result then return { ok = false, code = scanErr } end
  return {
    ok = true, action = 'scan', mode = mode, vehicle = result,
    flagOptions = configuredOptions(MZPoliceConfig.Enforcement.flags),
    impoundReasons = configuredOptions(MZPoliceConfig.Enforcement.impoundReasons)
  }
end

function Enforcement.flag(source, payload)
  if not closed(payload, FLAG_KEYS) then return { ok = false, code = 'invalid_payload' } end
  if not rateAllowed(source) then return { ok = false, code = 'rate_limited' } end
  local flagCode = key(payload.flagCode, 48)
  local configured = flagCode and MZPoliceConfig.Enforcement.flags[flagCode] or nil
  if type(configured) ~= 'table' or configured.enabled == false or type(payload.active) ~= 'boolean' then
    return { ok = false, code = 'flag_not_configured' }
  end
  local reference = trim(payload.reference)
  if #reference > 96 then return { ok = false, code = 'invalid_reference' } end
  return replay(source, payload.requestId, table.concat({ 'flag', trim(payload.scanId), flagCode, tostring(payload.active), reference }, ':'), function(requestId)
    local decision, authErr = authorize(source, 'police.anpr')
    if not decision then return { ok = false, code = authErr } end
    local operationId = ('vehicle-flag:%s:%s'):format(decision.identity.sessionId, requestId)
    local result, flagErr = MZPolice.Bridge.setVehicleFlag(
      source, payload.scanId, flagCode, payload.active, reference, operationId
    )
    MZPolice.Audit.enforcement('flag', decision.identity, {
      orgCode = decision.organization.code, plate = result and result.plate, operationId = operationId,
      flagCode = flagCode, result = result and 'updated' or 'denied', reason = flagErr
    })
    if not result then return { ok = false, code = flagErr } end
    return { ok = true, action = 'flag', code = 'vehicle_flag_updated', result = result }
  end)
end

function Enforcement.impound(source, payload)
  if not closed(payload, IMPOUND_KEYS) then return { ok = false, code = 'invalid_payload' } end
  if not rateAllowed(source) then return { ok = false, code = 'rate_limited' } end
  local reasonCode = key(payload.reasonCode, 48)
  local configured = reasonCode and MZPoliceConfig.Enforcement.impoundReasons[reasonCode] or nil
  if type(configured) ~= 'table' or configured.enabled == false then
    return { ok = false, code = 'impound_reason_not_configured' }
  end
  local reason = trim(configured.reason or configured.label)
  local reference = trim(payload.reference)
  if reason == '' or #reason > 160 or #reference > 96 then return { ok = false, code = 'invalid_impound_request' } end
  return replay(source, payload.requestId, table.concat({ 'impound', trim(payload.scanId), reasonCode, reference }, ':'), function(requestId)
    local decision, authErr = authorize(source, 'police.impound')
    if not decision then return { ok = false, code = authErr } end
    local operationId = ('vehicle-impound:%s:%s'):format(decision.identity.sessionId, requestId)
    local result, impoundErr = MZPolice.Bridge.impoundScannedVehicle(
      source, payload.scanId, reason, reference, operationId
    )
    MZPolice.Audit.enforcement('impound', decision.identity, {
      orgCode = decision.organization.code, plate = result and result.plate, operationId = operationId,
      reasonCode = reasonCode, result = result and 'impounded' or 'denied', reason = impoundErr
    })
    if not result then return { ok = false, code = impoundErr } end
    return { ok = true, action = 'impound', code = 'vehicle_impounded', result = result }
  end)
end

local function playerPosition(source)
  local ped = GetPlayerPed(source)
  if not ped or ped == 0 or (type(DoesEntityExist) == 'function' and not DoesEntityExist(ped)) then return nil end
  local coords = GetEntityCoords(ped)
  local forward = GetEntityForwardVector(ped)
  if not coords or not forward then return nil end
  local distance = tonumber(MZPoliceConfig.RoadObjects.placementDistance) or 2.0
  return {
    x = tonumber(coords.x or coords[1]) + tonumber(forward.x or forward[1]) * distance,
    y = tonumber(coords.y or coords[2]) + tonumber(forward.y or forward[2]) * distance,
    z = tonumber(coords.z or coords[3]),
    heading = tonumber(GetEntityHeading(ped)) or 0.0
  }
end

local function countFor(source)
  local count = 0
  for _, object in pairs(objects) do if object.source == tonumber(source) then count = count + 1 end end
  return count
end

function Enforcement.placeObject(source, payload)
  if not closed(payload, PLACE_KEYS) then return { ok = false, code = 'invalid_payload' } end
  if not rateAllowed(source) then return { ok = false, code = 'rate_limited' } end
  local objectType = key(payload.objectType, 48)
  local configured = objectType and MZPoliceConfig.RoadObjects.types[objectType] or nil
  if type(configured) ~= 'table' or configured.enabled == false then return { ok = false, code = 'road_object_not_configured' } end
  return replay(source, payload.requestId, ('road-place:%s'):format(objectType), function(requestId)
    local decision, authErr = authorize(source, MZPoliceConfig.RoadObjects.capability)
    if not decision then return { ok = false, code = authErr } end
    if countFor(source) >= (tonumber(MZPoliceConfig.RoadObjects.maximumPerOfficer) or 6)
      or (function() local n = 0; for _ in pairs(objects) do n = n + 1 end; return n end)()
        >= (tonumber(MZPoliceConfig.RoadObjects.maximumGlobal) or 60) then
      return { ok = false, code = 'road_object_limit' }
    end
    local position = playerPosition(source)
    if not position then return { ok = false, code = 'position_unavailable' } end
    local model = configured.model
    local modelHash = type(model) == 'number' and model or GetHashKey(tostring(model or ''))
    if not modelHash or modelHash == 0 then return { ok = false, code = 'road_object_model_invalid' } end
    local entity = CreateObjectNoOffset(modelHash, position.x, position.y, position.z, true, true, false)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return { ok = false, code = 'road_object_create_failed' } end
    SetEntityHeading(entity, position.heading)
    FreezeEntityPosition(entity, true)
    objectSequence = objectSequence + 1
    local objectId = ('road:%s:%s'):format(decision.identity.sessionId, objectSequence)
    objects[objectId] = {
      id = objectId, entity = entity, source = tonumber(source), identity = copy(decision.identity),
      organization = copy(decision.organization), objectType = objectType, createdAt = os.time()
    }
    MZPolice.Audit.enforcement('road_object_place', decision.identity, {
      orgCode = decision.organization.code, objectId = objectId, objectType = objectType,
      operationId = requestId, result = 'placed'
    })
    return { ok = true, action = 'road_place', code = 'road_object_placed', objectId = objectId, objectType = objectType }
  end)
end

local function nearestTrackedObject(source)
  local ped = GetPlayerPed(source)
  local origin = ped and GetEntityCoords(ped) or nil
  if not origin then return nil end
  local selected, selectedDistance
  for _, object in pairs(objects) do
    if object.entity and DoesEntityExist(object.entity) then
      local coords = GetEntityCoords(object.entity)
      local dx, dy, dz = tonumber(origin.x) - tonumber(coords.x), tonumber(origin.y) - tonumber(coords.y), tonumber(origin.z) - tonumber(coords.z)
      local distance = dx * dx + dy * dy + dz * dz
      if distance <= (tonumber(MZPoliceConfig.RoadObjects.removalDistance) or 8.0) ^ 2
        and (not selectedDistance or distance < selectedDistance) then
        selected, selectedDistance = object, distance
      end
    end
  end
  return selected
end

local function deleteObject(object)
  if object and object.entity and DoesEntityExist(object.entity) then DeleteEntity(object.entity) end
  if object then objects[object.id] = nil end
end

function Enforcement.removeNearestObject(source, payload)
  if not closed(payload, REMOVE_KEYS) then return { ok = false, code = 'invalid_payload' } end
  if not rateAllowed(source) then return { ok = false, code = 'rate_limited' } end
  return replay(source, payload.requestId, 'road-remove-nearest', function(requestId)
    local decision, authErr = authorize(source, MZPoliceConfig.RoadObjects.capability)
    if not decision then return { ok = false, code = authErr } end
    local object = nearestTrackedObject(source)
    if not object then return { ok = false, code = 'road_object_not_found_nearby' } end
    deleteObject(object)
    MZPolice.Audit.enforcement('road_object_remove', decision.identity, {
      orgCode = decision.organization.code, objectId = object.id, objectType = object.objectType,
      operationId = requestId, result = 'removed'
    })
    return { ok = true, action = 'road_remove', code = 'road_object_removed', objectId = object.id }
  end)
end

function Enforcement.cleanupSource(source, reason)
  source = tonumber(source)
  rateLimits[source], terminals[source] = nil, nil
  local remove = {}
  for _, object in pairs(objects) do if object.source == source then remove[#remove + 1] = object end end
  for _, object in ipairs(remove) do deleteObject(object) end
end

function Enforcement.sweep()
  local cutoff = GetGameTimer() - (tonumber(MZPoliceConfig.Enforcement.requestRetentionMs) or 120000)
  for source, bucket in pairs(terminals) do
    for requestId, terminal in pairs(bucket) do if terminal.createdAt < cutoff then bucket[requestId] = nil end end
  end
  local cleanup = {}
  for _, object in pairs(objects) do
    local decision = MZPolice.Policy.authorize(object.source, MZPoliceConfig.RoadObjects.capability)
    if decision.ok ~= true or decision.identity.sessionId ~= object.identity.sessionId
      or not DoesEntityExist(object.entity) then cleanup[#cleanup + 1] = object end
  end
  for _, object in ipairs(cleanup) do deleteObject(object) end
end

function Enforcement.stop()
  local cleanup = {}
  for _, object in pairs(objects) do cleanup[#cleanup + 1] = object end
  for _, object in ipairs(cleanup) do deleteObject(object) end
  rateLimits, terminals = {}, {}
end

MZPolice.Enforcement = Enforcement
