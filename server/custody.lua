MZPolice = MZPolice or {}

local Custody = {}
local states = {}
local requestCache = {}
local rateLimits = {}
local targetLocks = {}
local running = false

local ACTIONS = {
  cuff = true,
  uncuff = true,
  escort_start = true,
  escort_stop = true,
  vehicle_put = true,
  vehicle_remove = true
}

local PAYLOAD_KEYS = {
  action = true,
  targetSource = true,
  requestId = true,
  expectedRevision = true
}

local function nowMs()
  if type(GetGameTimer) == 'function' then return tonumber(GetGameTimer()) or 0 end
  return os.time() * 1000
end

local function result(ok, code, extra)
  local value = { ok = ok == true, code = tostring(code) }
  for key, item in pairs(type(extra) == 'table' and extra or {}) do value[key] = item end
  return value
end

local function copy(value)
  if type(value) ~= 'table' then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = copy(item) end
  return out
end

local function normalizeRequest(payload)
  if type(payload) ~= 'table' then return nil, 'invalid_payload' end
  for key in pairs(payload) do
    if not PAYLOAD_KEYS[key] then return nil, 'invalid_payload' end
  end

  local action = tostring(payload.action or ''):lower()
  local targetSource = tonumber(payload.targetSource)
  local requestId = tostring(payload.requestId or '')
  local expectedRevision = tonumber(payload.expectedRevision)
  if not ACTIONS[action] then return nil, 'invalid_action' end
  if not targetSource or targetSource <= 0 or targetSource % 1 ~= 0 then return nil, 'invalid_target' end
  if #requestId < 8 or #requestId > 96 or not requestId:match('^[%w:_-]+$') then
    return nil, 'invalid_request_id'
  end
  if not expectedRevision or expectedRevision < 0 or expectedRevision % 1 ~= 0 then
    return nil, 'invalid_revision'
  end
  return {
    action = action,
    targetSource = targetSource,
    requestId = requestId,
    expectedRevision = expectedRevision
  }
end

local function rateAllowed(source)
  local settings = MZPoliceConfig.Custody.rateLimit
  local current = nowMs()
  local bucket = rateLimits[source]
  if not bucket or current - bucket.startedAt >= settings.windowMs then
    rateLimits[source] = { startedAt = current, count = 1 }
    return true
  end
  if bucket.count >= settings.maximum then return false end
  bucket.count = bucket.count + 1
  return true
end

local function coordsFor(source)
  if type(GetPlayerPed) ~= 'function' or type(GetEntityCoords) ~= 'function' then return nil end
  local ok, ped = pcall(GetPlayerPed, source)
  if not ok or not ped or ped == 0 then return nil end
  if type(DoesEntityExist) == 'function' then
    local existsOk, exists = pcall(DoesEntityExist, ped)
    if not existsOk or exists ~= true then return nil end
  end
  local coordsOk, coords = pcall(GetEntityCoords, ped)
  if not coordsOk or not coords then return nil end
  local x, y, z = tonumber(coords.x or coords[1]), tonumber(coords.y or coords[2]), tonumber(coords.z or coords[3])
  if not x or not y or not z then return nil end
  return { x = x, y = y, z = z }
end

local function validateProximity(leftSource, rightSource)
  if type(GetPlayerRoutingBucket) == 'function' then
    local leftBucket = tonumber(GetPlayerRoutingBucket(leftSource))
    local rightBucket = tonumber(GetPlayerRoutingBucket(rightSource))
    if leftBucket == nil or rightBucket == nil or leftBucket ~= rightBucket then
      return false, 'routing_bucket_mismatch'
    end
  end
  local left, right = coordsFor(leftSource), coordsFor(rightSource)
  if not left or not right then return false, 'position_unavailable' end
  local dx, dy, dz = left.x - right.x, left.y - right.y, left.z - right.z
  local maximum = tonumber(MZPoliceConfig.Custody.maximumDistance) or 2.5
  if dx * dx + dy * dy + dz * dz > maximum * maximum then return false, 'target_too_far' end
  return true
end

local function squaredDistance(left, right)
  local dx, dy, dz = left.x - right.x, left.y - right.y, left.z - right.z
  return dx * dx + dy * dy + dz * dz
end

local function entityCoords(entity)
  if type(GetEntityCoords) ~= 'function' then return nil end
  local ok, value = pcall(GetEntityCoords, entity)
  if not ok or not value then return nil end
  local x, y, z = tonumber(value.x or value[1]), tonumber(value.y or value[2]), tonumber(value.z or value[3])
  if not x or not y or not z then return nil end
  return { x = x, y = y, z = z }
end

local function validVehicle(entity, bucket)
  if not entity or entity == 0 or type(DoesEntityExist) ~= 'function' or not DoesEntityExist(entity) then return false end
  if type(IsEntityAVehicle) == 'function' and not IsEntityAVehicle(entity) then return false end
  if type(GetEntityRoutingBucket) == 'function' and tonumber(GetEntityRoutingBucket(entity)) ~= tonumber(bucket) then
    return false
  end
  return true
end

local function networkId(entity)
  if type(NetworkGetNetworkIdFromEntity) ~= 'function' then return nil end
  local value = tonumber(NetworkGetNetworkIdFromEntity(entity))
  return value and value > 0 and value or nil
end

local function resolvePutVehicle(actorSource, targetSource)
  if type(GetAllVehicles) ~= 'function' or type(GetVehicleMaxNumberOfPassengers) ~= 'function'
    or type(GetPedInVehicleSeat) ~= 'function' then
    return nil, 'vehicle_runtime_unavailable'
  end
  local actorCoords, targetCoords = coordsFor(actorSource), coordsFor(targetSource)
  if not actorCoords or not targetCoords then return nil, 'position_unavailable' end
  local bucket = type(GetPlayerRoutingBucket) == 'function' and GetPlayerRoutingBucket(targetSource) or 0
  local maximum = tonumber(MZPoliceConfig.Custody.vehicleMaximumDistance) or 5.0
  local maximumSquared = maximum * maximum
  local selected, selectedSeat, selectedDistance
  for _, vehicle in ipairs(GetAllVehicles() or {}) do
    if validVehicle(vehicle, bucket) then
      local coords = entityCoords(vehicle)
      local distance = coords and squaredDistance(targetCoords, coords) or math.huge
      if distance <= maximumSquared and squaredDistance(actorCoords, coords) <= maximumSquared
        and (not selectedDistance or distance < selectedDistance) then
        local maxPassengers = math.max(0, math.floor(tonumber(GetVehicleMaxNumberOfPassengers(vehicle)) or 0))
        if maxPassengers > 0 then
          for seat = 0, maxPassengers - 1 do
            if tonumber(GetPedInVehicleSeat(vehicle, seat)) == 0 then
              selected, selectedSeat, selectedDistance = vehicle, seat, distance
              break
            end
          end
        end
      end
    end
  end
  if not selected then return nil, 'vehicle_seat_unavailable' end
  local netId = networkId(selected)
  if not netId then return nil, 'vehicle_not_networked' end
  return { entity = selected, networkId = netId, seat = selectedSeat, bucket = tonumber(bucket) or 0 }
end

local function resolveRemoveVehicle(targetSource)
  if type(GetPlayerPed) ~= 'function' or type(GetVehiclePedIsIn) ~= 'function' then
    return nil, 'vehicle_runtime_unavailable'
  end
  local ped = GetPlayerPed(targetSource)
  if not ped or ped == 0 then return nil, 'position_unavailable' end
  local vehicle = GetVehiclePedIsIn(ped, false)
  local bucket = type(GetPlayerRoutingBucket) == 'function' and GetPlayerRoutingBucket(targetSource) or 0
  if not validVehicle(vehicle, bucket) then return nil, 'target_not_in_vehicle' end
  local netId = networkId(vehicle)
  if not netId then return nil, 'vehicle_not_networked' end
  return { entity = vehicle, networkId = netId, bucket = tonumber(bucket) or 0 }
end

local function alive(source)
  local death, err = MZPolice.Bridge.getDeathState(source)
  if not death then return false, err end
  return tostring(death.deathState or '') == 'alive', 'player_not_alive'
end

local function identityMatches(reference)
  local identity = MZPolice.Bridge.resolveIdentity(reference.source)
  return identity
    and identity.sessionId == reference.sessionId
    and identity.characterId == reference.characterId
    and identity.citizenid == reference.citizenid
end

local function requestKey(actor, requestId)
  return ('%s:%s:%s'):format(actor.source, actor.sessionId, requestId)
end

local function cleanupRequestCache()
  local current = nowMs()
  for key, entry in pairs(requestCache) do
    if current >= entry.expiresAt then requestCache[key] = nil end
  end
end

local function replay(actor, request)
  cleanupRequestCache()
  local entry = requestCache[requestKey(actor, request.requestId)]
  if not entry then return nil end
  local fingerprint = ('%s:%s:%s'):format(request.action, request.targetSource, request.expectedRevision)
  if entry.fingerprint ~= fingerprint then return result(false, 'request_id_conflict') end
  return copy(entry.result)
end

local function remember(actor, request, response)
  requestCache[requestKey(actor, request.requestId)] = {
    fingerprint = ('%s:%s:%s'):format(request.action, request.targetSource, request.expectedRevision),
    result = copy(response),
    expiresAt = nowMs() + (tonumber(MZPoliceConfig.Custody.requestRetentionMs) or 120000)
  }
end

local function syncOfficer(source, targetSource, escorting, revision)
  if not source then return end
  TriggerClientEvent('mz_police:client:custody:officerSync', source, {
    targetSource = targetSource,
    escorting = escorting == true,
    revision = revision
  })
end

local function syncTarget(targetSource, state, reason)
  TriggerClientEvent('mz_police:client:custody:sync', targetSource, {
    revision = state and state.revision or 0,
    cuffed = state and state.cuffed == true or false,
    escortSource = state and state.escort and state.escort.source or nil,
    vehicleNetId = state and state.vehicle and state.vehicle.networkId or nil,
    vehicleSeat = state and state.vehicle and state.vehicle.seat or nil,
    reason = reason
  })
end

local function releaseTarget(targetSource, reason)
  local state = states[targetSource]
  if not state then return false end
  states[targetSource] = nil
  local revision = state.revision + 1
  if state.escort then syncOfficer(state.escort.source, targetSource, false, revision) end
  syncTarget(targetSource, { revision = revision, cuffed = false }, reason)
  MZPolice.Audit.custodyCleanup(state.target, { revision = revision, reason = reason })
  return true
end

local function transition(actor, target, request, authorization, vehicleContext)
  local state = states[target.source]
  local currentRevision = state and state.revision or 0
  if request.expectedRevision ~= currentRevision then
    return result(false, 'revision_conflict', { revision = currentRevision })
  end

  local oldEscort = state and state.escort or nil
  if request.action == 'cuff' then
    if state and state.cuffed then return result(false, 'already_cuffed', { revision = currentRevision }) end
    state = {
      revision = currentRevision + 1,
      cuffed = true,
      target = copy(target),
      cuffedBy = copy(actor)
    }
    states[target.source] = state
  elseif request.action == 'uncuff' then
    if not state or not state.cuffed then return result(false, 'not_cuffed', { revision = currentRevision }) end
    state.revision = currentRevision + 1
    states[target.source] = nil
  elseif request.action == 'escort_start' then
    if not state or not state.cuffed then return result(false, 'not_cuffed', { revision = currentRevision }) end
    if state.escort then return result(false, 'already_escorted', { revision = currentRevision }) end
    if state.vehicle then return result(false, 'target_in_vehicle', { revision = currentRevision }) end
    local actorState = states[actor.source]
    if actorState and actorState.cuffed then return result(false, 'actor_cuffed', { revision = currentRevision }) end
    state.revision = currentRevision + 1
    state.escort = copy(actor)
  elseif request.action == 'escort_stop' then
    if not state or not state.escort then return result(false, 'not_escorted', { revision = currentRevision }) end
    state.revision = currentRevision + 1
    state.escort = nil
  elseif request.action == 'vehicle_put' then
    if not state or not state.cuffed then return result(false, 'not_cuffed', { revision = currentRevision }) end
    if state.vehicle then return result(false, 'target_in_vehicle', { revision = currentRevision }) end
    if not vehicleContext then return result(false, 'vehicle_unavailable', { revision = currentRevision }) end
    state.revision = currentRevision + 1
    state.escort = nil
    vehicleContext.confirmed = false
    vehicleContext.confirmBy = nowMs() + (tonumber(MZPoliceConfig.Custody.vehicleConfirmationMs) or 3000)
    state.vehicle = copy(vehicleContext)
  elseif request.action == 'vehicle_remove' then
    if not state or not state.cuffed then return result(false, 'not_cuffed', { revision = currentRevision }) end
    if not vehicleContext then return result(false, 'target_not_in_vehicle', { revision = currentRevision }) end
    state.revision = currentRevision + 1
    state.vehicle = nil
  end

  local revision = state.revision
  if oldEscort and (not state.escort or oldEscort.source ~= state.escort.source) then
    syncOfficer(oldEscort.source, target.source, false, revision)
  end
  if state.escort then syncOfficer(state.escort.source, target.source, true, revision) end
  syncTarget(target.source,
    request.action == 'uncuff' and { revision = revision, cuffed = false } or state,
    request.action
  )

  local response = result(true, 'custody_updated', {
    action = request.action,
    targetSource = target.source,
    revision = revision,
    cuffed = request.action ~= 'uncuff' and state.cuffed == true or false,
    escortSource = request.action ~= 'uncuff' and state.escort and state.escort.source or nil,
    vehicleNetId = request.action ~= 'uncuff' and state.vehicle and state.vehicle.networkId or nil,
    vehicleSeat = request.action ~= 'uncuff' and state.vehicle and state.vehicle.seat or nil
  })
  MZPolice.Audit.custody(request.action, actor, target, {
    orgCode = authorization.organization.code,
    capability = authorization.capability,
    requestId = request.requestId,
    revision = revision,
    result = response.code
  })
  return response
end

function Custody.request(actorSource, payload)
  actorSource = tonumber(actorSource)
  if not actorSource or actorSource <= 0 then return result(false, 'invalid_source') end
  local request, requestErr = normalizeRequest(payload)
  if not request then return result(false, requestErr) end
  if request.targetSource == actorSource then return result(false, 'self_target_forbidden') end
  if not rateAllowed(actorSource) then return result(false, 'rate_limited') end

  local authorization = MZPolice.Policy.authorize(actorSource, MZPoliceConfig.Custody.capability)
  if authorization.ok ~= true then return result(false, authorization.code) end
  local actor = authorization.identity
  local replayed = replay(actor, request)
  if replayed then return replayed end

  if targetLocks[request.targetSource] then return result(false, 'target_busy') end
  targetLocks[request.targetSource] = requestKey(actor, request.requestId)

  local response
  local ok, err = pcall(function()
    local target, identityErr = MZPolice.Bridge.resolveIdentity(request.targetSource)
    if not target then response = result(false, identityErr); return end
    local actorAlive, actorStateErr = alive(actorSource)
    if not actorAlive then response = result(false, actorStateErr); return end
    local targetAlive, targetStateErr = alive(request.targetSource)
    if not targetAlive then response = result(false, targetStateErr); return end
    local close, proximityErr = validateProximity(actorSource, request.targetSource)
    if not close then response = result(false, proximityErr); return end
    local vehicleContext
    if request.action == 'vehicle_put' then
      vehicleContext, proximityErr = resolvePutVehicle(actorSource, request.targetSource)
      if not vehicleContext then response = result(false, proximityErr); return end
    elseif request.action == 'vehicle_remove' then
      vehicleContext, proximityErr = resolveRemoveVehicle(request.targetSource)
      if not vehicleContext then response = result(false, proximityErr); return end
    end
    response = transition(actor, target, request, authorization, vehicleContext)
  end)

  targetLocks[request.targetSource] = nil
  if not ok then
    print(('[mz_police][custody] request failed safely: %s'):format(tostring(err)))
    response = result(false, 'internal_error')
  end
  remember(actor, request, response)
  return response
end

function Custody.get(targetSource)
  return copy(states[tonumber(targetSource)])
end

function Custody.vehicleAck(targetSource, payload)
  targetSource = tonumber(targetSource)
  if not targetSource or targetSource <= 0 or type(payload) ~= 'table' then return false end
  for key in pairs(payload) do
    if key ~= 'revision' and key ~= 'networkId' then return false end
  end
  local revision, acknowledgedNetId = tonumber(payload.revision), tonumber(payload.networkId)
  local state = states[targetSource]
  if not state or not state.vehicle or revision ~= state.revision
    or acknowledgedNetId ~= state.vehicle.networkId then return false end
  if not identityMatches(state.target) then return false end
  if type(GetPlayerPed) ~= 'function' or type(GetVehiclePedIsIn) ~= 'function' then return false end
  local ped = GetPlayerPed(targetSource)
  local vehicle = ped and ped ~= 0 and GetVehiclePedIsIn(ped, false) or 0
  if vehicle == 0 or networkId(vehicle) ~= state.vehicle.networkId then return false end
  state.vehicle.confirmed = true
  return true
end

function Custody.cleanupSource(source, reason)
  source = tonumber(source)
  if not source then return end
  rateLimits[source] = nil
  releaseTarget(source, reason)
  local targets = {}
  for targetSource, state in pairs(states) do
    if (state.cuffedBy and state.cuffedBy.source == source)
      or (state.escort and state.escort.source == source) then
      targets[#targets + 1] = targetSource
    end
  end
  for _, targetSource in ipairs(targets) do releaseTarget(targetSource, reason) end
end

function Custody.sweep()
  local targets = {}
  for targetSource in pairs(states) do targets[#targets + 1] = targetSource end
  for _, targetSource in ipairs(targets) do
    local state = states[targetSource]
    local reason
    if not state or not identityMatches(state.target) then
      reason = 'target_session_changed'
    else
      local targetAlive = alive(targetSource)
      if not targetAlive then reason = 'target_not_alive' end
    end
    if not reason and (not state.cuffedBy or not identityMatches(state.cuffedBy)) then
      reason = 'actor_session_changed'
    end
    if not reason then
      local authorization = MZPolice.Policy.authorize(state.cuffedBy.source, MZPoliceConfig.Custody.capability)
      if authorization.ok ~= true then reason = 'actor_authority_lost' end
    end
    if not reason then
      local actorAlive = alive(state.cuffedBy.source)
      if not actorAlive then reason = 'actor_not_alive' end
    end
    if not reason and state.escort and not identityMatches(state.escort) then
      reason = 'escort_session_changed'
    end
    if not reason and state.escort then
      local escortAuthorization = MZPolice.Policy.authorize(state.escort.source, MZPoliceConfig.Custody.capability)
      if escortAuthorization.ok ~= true then reason = 'escort_authority_lost' end
    end
    if not reason and state.vehicle and not state.vehicle.confirmed
      and nowMs() >= tonumber(state.vehicle.confirmBy or 0) then
      state.revision = state.revision + 1
      state.vehicle = nil
      syncTarget(targetSource, state, 'vehicle_put_unconfirmed')
    elseif not reason and state.vehicle and state.vehicle.confirmed
      and type(GetPlayerPed) == 'function' and type(GetVehiclePedIsIn) == 'function' then
      local ped = GetPlayerPed(targetSource)
      local vehicle = ped and ped ~= 0 and GetVehiclePedIsIn(ped, false) or 0
      if vehicle == 0 or networkId(vehicle) ~= state.vehicle.networkId then
        state.revision = state.revision + 1
        state.vehicle = nil
        syncTarget(targetSource, state, 'vehicle_state_changed')
      end
    end
    if reason then releaseTarget(targetSource, reason) end
  end
  if MZPolice.Search then MZPolice.Search.sweep() end
end

function Custody.start()
  if running then return false end
  running = true
  if type(CreateThread) == 'function' and type(Wait) == 'function' then
    CreateThread(function()
      while running do
        Wait(tonumber(MZPoliceConfig.Custody.cleanupIntervalMs) or 1000)
        Custody.sweep()
      end
    end)
  end
  return true
end

function Custody.stop(reason)
  running = false
  local targets = {}
  for targetSource in pairs(states) do targets[#targets + 1] = targetSource end
  for _, targetSource in ipairs(targets) do releaseTarget(targetSource, reason or 'resource_stop') end
end

MZPolice.Custody = Custody
