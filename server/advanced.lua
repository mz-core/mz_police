MZPolice = MZPolice or {}

local Advanced = {}
local states, terminals, rateLimits, spotlightLimits = {}, {}, {}, {}

local function result(ok, code, extra)
  local out = { ok = ok == true, code = tostring(code or '') }
  for key, value in pairs(type(extra) == 'table' and extra or {}) do out[key] = value end
  return out
end

local function copy(value)
  if type(value) ~= 'table' then return value end
  local out = {}
  for key, entry in pairs(value) do out[key] = copy(entry) end
  return out
end

local function trim(value)
  return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function token(value, minimum, maximum)
  value = trim(value)
  if #value < minimum or #value > maximum or not value:match('^[%w:_-]+$') then return nil end
  return value
end

local function closed(payload, allowed)
  if type(payload) ~= 'table' then return false end
  for key in pairs(payload) do if allowed[key] ~= true then return false end end
  return true
end

local function settings()
  return type(MZPoliceConfig.Advanced) == 'table' and MZPoliceConfig.Advanced or {}
end

local function section(name)
  local value = settings()[name]
  return type(value) == 'table' and value or {}
end

local function available(name)
  return settings().enabled == true and section(name).enabled == true
end

local function ttl()
  return math.max(5, math.min(60, math.floor(tonumber(settings().stateTtlSeconds) or 12)))
end

local function rateAllowed(source)
  local config, now = settings().rateLimit or {}, GetGameTimer()
  local duration = math.max(1000, math.floor(tonumber(config.windowMs) or 10000))
  local maximum = math.max(1, math.floor(tonumber(config.maximum) or 20))
  local window = rateLimits[source]
  if not window or now - window.startedAt >= duration then
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

local function spotlightAllowed(source)
  local now = GetGameTimer()
  local window = spotlightLimits[source]
  if not window or now - window.startedAt >= 2000 then
    spotlightLimits[source] = { startedAt = now, count = 1 }
    return true
  end
  window.count = window.count + 1
  return window.count <= 5
end

local function modelAllowed(catalog, vehicle)
  if type(catalog) ~= 'table' or type(vehicle) ~= 'table' then return false end
  return catalog[vehicle.model] == true
    or catalog[tostring(vehicle.modelHash or '')] == true
    or (vehicle.modelHash and catalog[vehicle.modelHash] == true)
end

local function occupiedVehicle(source, catalog)
  local vehicle, vehicleError = MZPolice.Bridge.resolveOccupiedVehicle(source)
  if not vehicle then return nil, vehicleError end
  if not modelAllowed(catalog, vehicle) then return nil, 'vehicle_not_authorized' end
  return vehicle
end

local function actorState(source, decision)
  local current = states[source]
  if not current or current.sessionId ~= decision.identity.sessionId
    or current.citizenid ~= decision.identity.citizenid then
    current = {
      sessionId = decision.identity.sessionId,
      citizenid = decision.identity.citizenid,
      orgCode = decision.organization.code
    }
    states[source] = current
  end
  return current
end

local function clearFeature(source, key)
  local current = states[source]
  if current then current[key] = nil end
end

local function sameActor(current, decision)
  return type(current) == 'table' and type(decision) == 'table'
    and type(decision.identity) == 'table'
    and current.sessionId == decision.identity.sessionId
    and current.citizenid == decision.identity.citizenid
end

local function deactivate(source, key, action, requestId)
  local current = states[source]
  if current and current[key] then
    local identity = MZPolice.Bridge.resolveIdentity(source)
    if identity and current.sessionId == identity.sessionId and current.citizenid == identity.citizenid then
      MZPolice.Audit.advanced(action, identity, {
        orgCode = current.orgCode, operationId = requestId, active = false, result = 'disabled'
      })
    end
  end
  clearFeature(source, key)
end

local function publicState(source)
  local current, now = states[source] or {}, os.time()
  local function active(key)
    if type(current[key]) ~= 'table' or not tonumber(current[key].expiresAt) or now >= current[key].expiresAt then
      current[key] = nil
      return false
    end
    return true
  end
  return {
    bodycam = active('bodycam'),
    dashcam = active('dashcam'),
    flir = active('flir'),
    tracker = active('tracker'),
    dashcamVehicle = active('dashcam') and copy(current.dashcam.vehicle) or nil,
    flirVehicle = active('flir') and copy(current.flir.vehicle) or nil
  }
end

local function fingerprint(...)
  local hash = 2166136261
  for index = 1, select('#', ...) do
    local value = tostring(select(index, ...) or '')
    for offset = 1, #value do hash = ((hash ~ value:byte(offset)) * 16777619) & 0xffffffff end
    hash = ((hash ~ 31) * 16777619) & 0xffffffff
  end
  return ('%08x'):format(hash)
end

local function replay(source, requestId, requestFingerprint, execute)
  local bucket = terminals[source] or {}
  terminals[source] = bucket
  local existing = bucket[requestId]
  if existing then
    if existing.fingerprint ~= requestFingerprint then return result(false, 'request_id_conflict') end
    return copy(existing.response)
  end
  local response = execute()
  bucket[requestId] = {
    fingerprint = requestFingerprint,
    response = copy(response),
    createdAt = GetGameTimer()
  }
  return response
end

local function audit(action, decision, fields)
  fields = type(fields) == 'table' and fields or {}
  fields.orgCode = decision.organization.code
  MZPolice.Audit.advanced(action, decision.identity, fields)
end

local function setSimpleCamera(source, active, requestId)
  if active ~= true then
    deactivate(source, 'bodycam', 'bodycam_state', requestId)
    return result(true, 'bodycam_inactive', { state = publicState(source) })
  end
  if not available('Cameras') then return result(false, 'advanced_cameras_disabled') end
  local config = section('Cameras')
  local decision, authError = authorize(source, config.useCapability)
  if not decision then return result(false, authError) end
  local current = actorState(source, decision)
  current.bodycam = { expiresAt = os.time() + ttl() }
  audit('bodycam_state', decision, { active = true, operationId = requestId, result = 'authorized' })
  return result(true, 'bodycam_active', { state = publicState(source) })
end

local function setDashcam(source, active, requestId)
  if active ~= true then
    deactivate(source, 'dashcam', 'dashcam_state', requestId)
    return result(true, 'dashcam_inactive', { state = publicState(source) })
  end
  if not available('Cameras') then return result(false, 'advanced_cameras_disabled') end
  local config = section('Cameras')
  local decision, authError = authorize(source, config.useCapability)
  if not decision then return result(false, authError) end
  local vehicle, vehicleError = occupiedVehicle(source, config.dashcamVehicles)
  if not vehicle then return result(false, vehicleError) end
  local current = actorState(source, decision)
  current.dashcam = { expiresAt = os.time() + ttl(), vehicle = vehicle }
  audit('dashcam_state', decision, {
    active = true, operationId = requestId, plate = vehicle.plate, result = 'authorized'
  })
  return result(true, 'dashcam_active', { state = publicState(source) })
end

local function cctvCatalog(source)
  if not available('Cameras') then return result(false, 'advanced_cameras_disabled') end
  local config = section('Cameras')
  local decision, authError = authorize(source, config.viewCapability)
  if not decision then return result(false, authError) end
  local cameras = {}
  for id, camera in pairs(type(config.cctv) == 'table' and config.cctv or {}) do
    if type(camera) == 'table' and camera.enabled == true then
      cameras[#cameras + 1] = {
        id = tostring(id), label = tostring(camera.label or id), location = tostring(camera.location or '')
      }
    end
  end
  table.sort(cameras, function(left, right) return left.id < right.id end)
  return result(true, 'cctv_catalog', { cameras = cameras })
end

local function cameraSnapshot(source)
  if not available('Cameras') then return result(false, 'advanced_cameras_disabled') end
  local config = section('Cameras')
  local viewer, authError = authorize(source, config.viewCapability)
  if not viewer then return result(false, authError) end
  local viewerBucket = type(GetPlayerRoutingBucket) == 'function' and tonumber(GetPlayerRoutingBucket(source)) or 0
  local cameras, now = {}, os.time()
  for unitSource, current in pairs(states) do
    local bodycamActive = type(current.bodycam) == 'table' and now < (tonumber(current.bodycam.expiresAt) or 0)
    local dashcamActive = type(current.dashcam) == 'table' and now < (tonumber(current.dashcam.expiresAt) or 0)
    if bodycamActive or dashcamActive then
      local authorized = authorize(unitSource, config.useCapability)
      local bucket = type(GetPlayerRoutingBucket) == 'function' and tonumber(GetPlayerRoutingBucket(unitSource)) or 0
      if not sameActor(current, authorized) or bucket ~= viewerBucket then
        current.bodycam, current.dashcam = nil, nil
      else
        cameras[#cameras + 1] = {
          unitId = current.citizenid,
          orgCode = current.orgCode,
          bodycam = bodycamActive,
          dashcam = dashcamActive,
          plate = dashcamActive and current.dashcam.vehicle.plate or nil
        }
      end
    end
  end
  table.sort(cameras, function(left, right) return left.unitId < right.unitId end)
  return result(true, 'camera_snapshot', { cameras = cameras, liveFeedAvailable = false })
end

local function openCctv(source, payload, requestId)
  if not closed(payload, { cameraId = true }) then return result(false, 'invalid_payload') end
  if not available('Cameras') then return result(false, 'advanced_cameras_disabled') end
  local config = section('Cameras')
  local decision, authError = authorize(source, config.viewCapability)
  if not decision then return result(false, authError) end
  local cameraId = token(payload.cameraId, 2, 48)
  local camera = cameraId and config.cctv[cameraId] or nil
  local coordinates = type(camera) == 'table' and camera.coordinates or nil
  local rotation = type(camera) == 'table' and camera.rotation or nil
  if type(camera) ~= 'table' or camera.enabled ~= true or type(coordinates) ~= 'table'
    or type(rotation) ~= 'table' or not tonumber(coordinates.x) or not tonumber(coordinates.y)
    or not tonumber(coordinates.z) or not tonumber(rotation.x) or not tonumber(rotation.y)
    or not tonumber(rotation.z) then return result(false, 'cctv_not_configured') end
  audit('cctv_open', decision, { cameraId = cameraId, operationId = requestId, result = 'authorized' })
  return result(true, 'cctv_authorized', {
    camera = {
      id = cameraId,
      label = tostring(camera.label or cameraId),
      location = tostring(camera.location or ''),
      coordinates = { x = tonumber(coordinates.x), y = tonumber(coordinates.y), z = tonumber(coordinates.z) },
      rotation = { x = tonumber(rotation.x), y = tonumber(rotation.y), z = tonumber(rotation.z) },
      fov = math.max(10.0, math.min(100.0, tonumber(camera.fov) or 45.0))
    },
    expiresAt = os.time() + ttl()
  })
end

local function setFlir(source, active, requestId)
  if active ~= true then
    deactivate(source, 'flir', 'flir_state', requestId)
    return result(true, 'flir_inactive', { state = publicState(source) })
  end
  if not available('Air') then return result(false, 'air_support_disabled') end
  local config = section('Air')
  if type(config.cameraOffset) ~= 'table' or not tonumber(config.cameraOffset.x)
    or not tonumber(config.cameraOffset.y) or not tonumber(config.cameraOffset.z) then
    return result(false, 'flir_camera_not_configured')
  end
  local decision, authError = authorize(source, config.capability)
  if not decision then return result(false, authError) end
  local vehicle, vehicleError = occupiedVehicle(source, config.helicopterModels)
  if not vehicle then return result(false, vehicleError) end
  local current = actorState(source, decision)
  current.flir = { expiresAt = os.time() + ttl(), vehicle = vehicle }
  audit('flir_state', decision, { active = true, operationId = requestId, plate = vehicle.plate, result = 'authorized' })
  return result(true, 'flir_active', {
    state = publicState(source),
    camera = {
      vehicleNetworkId = vehicle.networkId,
      offset = copy(config.cameraOffset),
      minimumFov = math.max(5.0, tonumber(config.minimumFov) or 10.0),
      maximumFov = math.min(100.0, tonumber(config.maximumFov) or 80.0)
    }
  })
end

local function setTracker(source, active, requestId)
  if active ~= true then
    deactivate(source, 'tracker', 'tracker_state', requestId)
    if MZPolice.TrackerV2 then MZPolice.TrackerV2.Revalidate(source) end
    return result(true, 'tracker_inactive', { state = publicState(source) })
  end
  if not available('Tracker') then return result(false, 'tracker_disabled') end
  local config = section('Tracker')
  local decision, authError = authorize(source, config.useCapability)
  if not decision then return result(false, authError) end
  local vehicle, vehicleError = occupiedVehicle(source, config.vehicleModels)
  if not vehicle then return result(false, vehicleError) end
  local current = actorState(source, decision)
  current.tracker = { expiresAt = os.time() + ttl(), vehicle = vehicle }
  if MZPolice.TrackerV2 then MZPolice.TrackerV2.Revalidate(source) end
  audit('tracker_state', decision, { active = true, operationId = requestId, plate = vehicle.plate, result = 'authorized' })
  return result(true, 'tracker_active', { state = publicState(source) })
end

-- Refletor do helicoptero: validado no servidor e replicado apenas para o
-- mesmo routing bucket da aeronave. Sem persistencia e sem estado de economia.
function Advanced.spotlight(source, active)
  source = tonumber(source)
  if not source or source <= 0 or type(active) ~= 'boolean' then return false, 'invalid_request' end
  if not spotlightAllowed(source) then return false, 'rate_limited' end
  if not available('Air') then return false, 'air_support_disabled' end
  local config = section('Air')
  local decision, authError = authorize(source, config.capability)
  if not decision then return false, authError end
  local vehicle, vehicleError = occupiedVehicle(source, config.helicopterModels)
  if not vehicle then return false, vehicleError end
  if vehicle.seat ~= -1 and vehicle.seat ~= 0 then return false, 'seat_not_authorized' end
  MZPolice.Audit.advanced('spotlight_state', decision.identity, {
    orgCode = decision.organization.code, active = active, plate = vehicle.plate, result = 'authorized'
  })
  local bucket = tonumber(vehicle.routingBucket) or 0
  if type(GetPlayers) == 'function' and type(GetPlayerRoutingBucket) == 'function' then
    for _, rawSource in ipairs(GetPlayers() or {}) do
      local target = tonumber(rawSource)
      if target and (tonumber(GetPlayerRoutingBucket(target)) or 0) == bucket then
        TriggerClientEvent('mz_police:client:heli:spotlight', target, vehicle.networkId, active)
      end
    end
  else
    TriggerClientEvent('mz_police:client:heli:spotlight', -1, vehicle.networkId, active)
  end
  return true, 'spotlight_updated'
end

local function trackerSnapshot(source)
  if not available('Tracker') then return result(false, 'tracker_disabled') end
  local config = section('Tracker')
  local viewer, authError = authorize(source, config.viewCapability)
  if not viewer then return result(false, authError) end
  local viewerBucket = type(GetPlayerRoutingBucket) == 'function' and tonumber(GetPlayerRoutingBucket(source)) or 0
  local units, now = {}, os.time()
  for unitSource, current in pairs(states) do
    local tracker = current.tracker
    if type(tracker) == 'table' and now < (tonumber(tracker.expiresAt) or 0) then
      local authorized = authorize(unitSource, config.useCapability)
      local vehicle = authorized and MZPolice.Bridge.resolveOccupiedVehicle(unitSource) or nil
      if not sameActor(current, authorized) or not vehicle or not modelAllowed(config.vehicleModels, vehicle)
        or tonumber(vehicle.routingBucket) ~= viewerBucket or vehicle.plate ~= tracker.vehicle.plate then
        current.tracker = nil
      else
        local entity = type(NetworkGetEntityFromNetworkId) == 'function'
          and NetworkGetEntityFromNetworkId(vehicle.networkId) or 0
        local coordinates = entity and entity ~= 0 and GetEntityCoords(entity) or nil
        if coordinates and tonumber(coordinates.x) and tonumber(coordinates.y) and tonumber(coordinates.z) then
          units[#units + 1] = {
            unitId = current.citizenid,
            plate = vehicle.plate,
            coordinates = { x = tonumber(coordinates.x), y = tonumber(coordinates.y), z = tonumber(coordinates.z) },
            heading = type(GetEntityHeading) == 'function' and tonumber(GetEntityHeading(entity)) or 0,
            expiresAt = tracker.expiresAt
          }
        end
      end
    end
  end
  local map, mapError = MZPolice.Bridge.getNavigationMapSnapshot(source)
  local response = {
    units = units,
    broadcasting = publicState(source).tracker,
    refreshMs = math.max(2000, math.floor(tonumber(config.refreshMs) or 3000)),
    staleAfterMs = math.max(5000, math.floor(tonumber(config.staleAfterMs) or 10000)),
    map = map
  }
  if not map then response.mapError = mapError end
  return result(true, 'tracker_snapshot', response)
end

local function linkedEvidence(case, instanceUid)
  for _, evidence in ipairs(type(case.evidence) == 'table' and case.evidence or {}) do
    if tostring(evidence.instance_uid or evidence.instanceUid or '') == instanceUid then return evidence end
  end
end

local function inventoryEvidence(source, orgCode, instanceUid)
  for containerId, config in pairs(MZPoliceConfig.Evidence.containers or {}) do
    if type(config) == 'table' and config.enabled ~= false then
      local items = MZPolice.Bridge.listPoliceEvidence(source, orgCode, containerId)
      if type(items) == 'table' then
        for _, item in ipairs(items) do
          if tostring(item.instanceUid or '') == instanceUid then return item, containerId end
        end
      end
    end
  end
end

local function forensicAnalysis(source, payload, requestId)
  if not closed(payload, { caseId = true, instanceUid = true, method = true }) then
    return result(false, 'invalid_payload')
  end
  if not available('Forensics') then return result(false, 'forensics_disabled') end
  if not MZPolice.RecordsPrepare.ready then return result(false, 'records_unavailable') end
  local config = section('Forensics')
  local method = token(payload.method, 2, 64)
  if not method or config.methods[method] ~= true then return result(false, 'forensic_method_disabled') end
  local decision, authError = authorize(source, config.capability)
  if not decision then return result(false, authError) end
  local caseId = token(payload.caseId, 8, 160)
  local instanceUid = token(payload.instanceUid, 1, 64)
  if not caseId or not instanceUid then return result(false, 'invalid_forensic_request') end
  local policeCase = MZPolice.RecordsRepository.getCase(decision.organization.code, caseId)
  local linked = policeCase and linkedEvidence(policeCase, instanceUid) or nil
  if not linked then return result(false, policeCase and 'evidence_not_linked' or 'case_not_found') end
  local evidence = inventoryEvidence(source, decision.organization.code, instanceUid)
  if not evidence then return result(false, 'evidence_not_in_custody') end
  local forensic = type(evidence.forensics) == 'table' and evidence.forensics or {}
  if method ~= 'weapon_identity' or forensic.kind ~= 'weapon' or trim(forensic.serial) == '' then
    return result(false, 'forensic_method_not_applicable')
  end
  local requestFingerprint = fingerprint(caseId, instanceUid, method, forensic.serial)
  local operationId = ('forensic:%s:%s'):format(decision.identity.citizenid, fingerprint(requestId))
  local existing = MZPolice.RecordsRepository.getHistoryOperation(operationId)
  if existing then
    if tostring(existing.request_fingerprint or '') ~= requestFingerprint then
      return result(false, 'request_id_conflict')
    end
    return result(true, 'forensic_result_replayed', {
      replayed = true,
      case = MZPolice.RecordsRepository.getCase(decision.organization.code, caseId)
    })
  end
  local evidenceId = tostring(linked.evidence_id or linked.evidenceId or '')
  local serial = trim(forensic.serial)
  if #serial > 96 then return result(false, 'forensic_metadata_invalid') end
  local publicId = operationId
  local derived = {
    source = 'mz_inventory.metadata.serial',
    item = tostring(evidence.item or ''),
    serial = serial
  }
  local saved = MZPolice.RecordsRepository.createForensicResult({
    publicId = publicId,
    operationId = operationId,
    orgCode = decision.organization.code,
    caseId = caseId,
    evidenceId = evidenceId,
    instanceUid = instanceUid,
    method = method,
    result = derived,
    actorCitizenid = decision.identity.citizenid,
    history = {
      operationId = operationId,
      orgCode = decision.organization.code,
      entityType = 'case',
      entityId = caseId,
      action = 'forensic_result_recorded',
      requestFingerprint = requestFingerprint,
      actorCitizenid = decision.identity.citizenid,
      details = { evidenceId = evidenceId, instanceUid = instanceUid, method = method, result = derived }
    }
  })
  if not saved then return result(false, 'persistence_failed') end
  audit('forensic_result', decision, {
    operationId = operationId, caseId = caseId, instanceUid = instanceUid,
    method = method, result = 'derived'
  })
  return result(true, 'forensic_result_recorded', {
    case = MZPolice.RecordsRepository.getCase(decision.organization.code, caseId)
  })
end

local function heartbeat(source, payload)
  if not closed(payload, { bodycam = true, dashcam = true, flir = true, tracker = true }) then
    return result(false, 'invalid_payload')
  end
  local response = publicState(source)
  if payload.bodycam == true and response.bodycam then
    local decision = available('Cameras') and authorize(source, section('Cameras').useCapability) or nil
    if sameActor(states[source], decision) then states[source].bodycam.expiresAt = os.time() + ttl()
    else clearFeature(source, 'bodycam') end
  end
  if payload.dashcam == true and response.dashcam then
    local decision = available('Cameras') and authorize(source, section('Cameras').useCapability) or nil
    local vehicle = decision and occupiedVehicle(source, section('Cameras').dashcamVehicles) or nil
    if sameActor(states[source], decision) and vehicle and vehicle.plate == states[source].dashcam.vehicle.plate then
      states[source].dashcam.expiresAt = os.time() + ttl()
      states[source].dashcam.vehicle = vehicle
    else clearFeature(source, 'dashcam') end
  end
  if payload.flir == true and response.flir then
    local decision = available('Air') and authorize(source, section('Air').capability) or nil
    local vehicle = decision and occupiedVehicle(source, section('Air').helicopterModels) or nil
    if sameActor(states[source], decision) and vehicle and vehicle.plate == states[source].flir.vehicle.plate then
      states[source].flir.expiresAt = os.time() + ttl()
      states[source].flir.vehicle = vehicle
    else clearFeature(source, 'flir') end
  end
  if payload.tracker == true and response.tracker then
    local decision = available('Tracker') and authorize(source, section('Tracker').useCapability) or nil
    local vehicle = decision and occupiedVehicle(source, section('Tracker').vehicleModels) or nil
    if sameActor(states[source], decision) and vehicle and vehicle.plate == states[source].tracker.vehicle.plate then
      states[source].tracker.expiresAt = os.time() + ttl()
      states[source].tracker.vehicle = vehicle
    else clearFeature(source, 'tracker') end
  end
  return result(true, 'advanced_heartbeat', { state = publicState(source) })
end

local handlers = {
  status = function(source)
    local decision, authError = authorize(source, MZPoliceConfig.Records.readCapability)
    if not decision then return result(false, authError) end
    actorState(source, decision)
    return result(true, 'advanced_status', {
      state = publicState(source),
      configured = {
        cameras = available('Cameras'), air = available('Air'),
        tracker = available('Tracker'), forensics = available('Forensics')
      }
    })
  end,
  bodycamToggle = function(source, payload, requestId)
    if not closed(payload, { active = true }) or type(payload.active) ~= 'boolean' then return result(false, 'invalid_payload') end
    return setSimpleCamera(source, payload.active, requestId)
  end,
  dashcamToggle = function(source, payload, requestId)
    if not closed(payload, { active = true }) or type(payload.active) ~= 'boolean' then return result(false, 'invalid_payload') end
    return setDashcam(source, payload.active, requestId)
  end,
  cctvList = function(source, payload)
    if not closed(payload, {}) then return result(false, 'invalid_payload') end
    return cctvCatalog(source)
  end,
  cameraSnapshot = function(source, payload)
    if not closed(payload, {}) then return result(false, 'invalid_payload') end
    return cameraSnapshot(source)
  end,
  cctvOpen = openCctv,
  flirToggle = function(source, payload, requestId)
    if not closed(payload, { active = true }) or type(payload.active) ~= 'boolean' then return result(false, 'invalid_payload') end
    return setFlir(source, payload.active, requestId)
  end,
  trackerBroadcast = function(source, payload, requestId)
    if not closed(payload, { active = true }) or type(payload.active) ~= 'boolean' then return result(false, 'invalid_payload') end
    return setTracker(source, payload.active, requestId)
  end,
  trackerSnapshot = function(source, payload)
    if not closed(payload, {}) then return result(false, 'invalid_payload') end
    return trackerSnapshot(source)
  end,
  trackerSubscribe = function(source, payload)
    if not closed(payload, { requestMap = true }) then return result(false, 'invalid_payload') end
    return MZPolice.TrackerV2.Subscribe(source, payload)
  end,
  trackerUnsubscribe = function(source, payload)
    if not closed(payload, {}) then return result(false, 'invalid_payload') end
    return MZPolice.TrackerV2.Unsubscribe(source)
  end,
  trackerRevalidate = function(source, payload)
    if not closed(payload, {}) then return result(false, 'invalid_payload') end
    MZPolice.TrackerV2.Revalidate(source)
    return result(true, 'tracker_revalidation_scheduled')
  end,
  heartbeat = heartbeat,
  forensicAnalyze = forensicAnalysis
}

function Advanced.request(source, envelope)
  if type(envelope) ~= 'table' then return result(false, 'invalid_request') end
  for key in pairs(envelope) do
    if key ~= 'action' and key ~= 'requestId' and key ~= 'payload' then return result(false, 'invalid_request') end
  end
  source = tonumber(source)
  local action = token(envelope.action, 2, 32)
  local requestId = token(envelope.requestId, 8, 96)
  local payload = type(envelope.payload) == 'table' and envelope.payload or nil
  local handler = action and handlers[action] or nil
  if not source or source <= 0 or not requestId or not payload or not handler then return result(false, 'invalid_request') end
  if not rateAllowed(source) then return result(false, 'rate_limited') end
  local query = action == 'status' or action == 'cctvList' or action == 'cameraSnapshot'
    or action == 'trackerSnapshot' or action == 'trackerSubscribe'
    or action == 'trackerUnsubscribe' or action == 'trackerRevalidate'
    or action == 'heartbeat'
    or action == 'forensicAnalyze'
  if query then return handler(source, payload, requestId) end
  return replay(source, requestId, fingerprint(action, json.encode(payload)), function()
    return handler(source, payload, requestId)
  end)
end

function Advanced.cleanupSource(source)
  source = tonumber(source)
  states[source], terminals[source], rateLimits[source], spotlightLimits[source] = nil, nil, nil, nil
  if MZPolice.TrackerV2 then MZPolice.TrackerV2.RemoveSource(source) end
end

function Advanced.sweep()
  local cutoff = GetGameTimer() - (tonumber(settings().requestRetentionMs) or 120000)
  for source, bucket in pairs(terminals) do
    for requestId, value in pairs(bucket) do if value.createdAt < cutoff then bucket[requestId] = nil end end
    if not next(bucket) then terminals[source] = nil end
  end
end

function Advanced.stop()
  states, terminals, rateLimits, spotlightLimits = {}, {}, {}, {}
  if MZPolice.TrackerV2 then MZPolice.TrackerV2.Stop() end
end

if MZPolice.TrackerV2 and type(MZPolice.TrackerV2.Attach) == 'function' then
  MZPolice.TrackerV2.Attach({
    states = states,
    authorize = authorize,
    occupiedVehicle = occupiedVehicle,
    modelAllowed = modelAllowed,
    sameActor = sameActor,
    trackerConfig = function() return section('Tracker') end,
    clearTracker = function(source) clearFeature(source, 'tracker') end,
    publicState = publicState,
    navigationMap = function(source)
      return MZPolice.Bridge.getNavigationMapSnapshot(source)
    end
  })
end

MZPolice.Advanced = Advanced
