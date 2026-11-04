MZPolice = MZPolice or {}

local Custody = {}
local states = {}
local requestCache = {}
local rateLimits = {}
local targetLocks = {}
local running = false
-- Identidade imutavel de UMA custodia. A revision muda a cada transicao, mas
-- pode voltar a 0/1 depois de desalgemar; o instanceId nao. Ele e a chave
-- natural idempotente da prisao rapida.
local custodySequence = 0

local ACTIONS = {
  cuff = true,
  uncuff = true,
  escort_start = true,
  escort_stop = true,
  transfer = true,
  vehicle_put = true,
  vehicle_remove = true
}

local PAYLOAD_KEYS = {
  action = true,
  targetSource = true,
  requestId = true,
  expectedRevision = true,
  newOfficerSource = true
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
  local newOfficerSource = tonumber(payload.newOfficerSource)
  if not ACTIONS[action] then return nil, 'invalid_action' end
  if not targetSource or targetSource <= 0 or targetSource % 1 ~= 0 then return nil, 'invalid_target' end
  if #requestId < 8 or #requestId > 96 or not requestId:match('^[%w:_-]+$') then
    return nil, 'invalid_request_id'
  end
  if not expectedRevision or expectedRevision < 0 or expectedRevision % 1 ~= 0 then
    return nil, 'invalid_revision'
  end
  if action == 'transfer' and (not newOfficerSource or newOfficerSource <= 0
    or newOfficerSource % 1 ~= 0 or newOfficerSource == targetSource) then
    return nil, 'transfer_target_invalid'
  end
  if action ~= 'transfer' and payload.newOfficerSource ~= nil then return nil, 'invalid_payload' end
  return {
    action = action,
    targetSource = targetSource,
    requestId = requestId,
    expectedRevision = expectedRevision,
    newOfficerSource = newOfficerSource
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
  -- Em OneSync DoesEntityExist pode falhar para ped de jogador fora do
  -- escopo de replica; GetEntityCoords continua sendo a fonte de posicao.
  local coordsOk, coords = pcall(GetEntityCoords, ped)
  if not coordsOk or not coords then return nil end
  local x, y, z = tonumber(coords.x or coords[1]), tonumber(coords.y or coords[2]), tonumber(coords.z or coords[3])
  if not x or not y or not z then return nil end
  return { x = x, y = y, z = z }
end

local function validateProximity(leftSource, rightSource, maximumOverride)
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
  local maximum = tonumber(maximumOverride) or tonumber(MZPoliceConfig.Custody.maximumDistance) or 2.5
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

local function alive(source, allowDowned)
  local death, err = MZPolice.Bridge.getDeathState(source)
  if not death then return false, err end
  local deathState = tostring(death.deathState or '')
  if deathState == 'alive' then return true end
  if allowDowned == true and deathState == 'downed' then return true end
  return false, 'player_not_alive'
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
  local fingerprint = ('%s:%s:%s:%s'):format(
    request.action, request.targetSource, request.expectedRevision, request.newOfficerSource or '')
  if entry.fingerprint ~= fingerprint then return result(false, 'request_id_conflict') end
  return copy(entry.result)
end

local function remember(actor, request, response)
  requestCache[requestKey(actor, request.requestId)] = {
    fingerprint = ('%s:%s:%s:%s'):format(
      request.action, request.targetSource, request.expectedRevision, request.newOfficerSource or ''),
    result = copy(response),
    expiresAt = nowMs() + (tonumber(MZPoliceConfig.Custody.requestRetentionMs) or 120000)
  }
end

local function restraintConfig()
  return type(MZPoliceConfig.Restraints) == 'table' and MZPoliceConfig.Restraints or {}
end

local function publicRestraint(state)
  local restraint = state and state.restraint
  if type(restraint) ~= 'table' then return nil end
  return {
    origin = tostring(restraint.origin or 'service'),
    serial = restraint.serial,
    appliedAt = tonumber(restraint.appliedAt),
    keyIssued = restraint.keyUid ~= nil and restraint.keyUid ~= '',
    persistent = restraint.persistent == true
  }
end

local function setRestraintStateBag(targetSource, state)
  if type(Player) ~= 'function' then return end
  local ok, player = pcall(Player, targetSource)
  if not ok or not player or not player.state then return end
  local cuffed = state and state.cuffed == true
  local settings = restraintConfig()
  pcall(function()
    player.state:set('mz:restrained', cuffed, true)
    player.state:set('mz:restrainedInventoryBlocked', cuffed and settings.inventoryWhileCuffed ~= true, true)
    player.state:set('mz:restraintRevision', state and tonumber(state.revision) or 0, true)
    player.state:set('mz:restraintOrigin',
      cuffed and state and state.restraint and state.restraint.origin or nil, true)
  end)
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
  local payload = {
    revision = state and state.revision or 0,
    cuffed = state and state.cuffed == true or false,
    escortSource = state and state.escort and state.escort.source or nil,
    vehicleNetId = state and state.vehicle and state.vehicle.networkId or nil,
    vehicleSeat = state and state.vehicle and state.vehicle.seat or nil,
    restraint = publicRestraint(state),
    reason = reason
  }
  TriggerClientEvent('mz_police:client:custody:sync', targetSource, payload)
  setRestraintStateBag(targetSource, state)
end

local function releaseTarget(targetSource, reason, options)
  local state = states[targetSource]
  if not state then return false end
  options = type(options) == 'table' and options or {}
  states[targetSource] = nil
  local revision = state.revision + 1
  state.revision = revision
  if MZPolice.Restraints and type(MZPolice.Restraints.onCustodyReleased) == 'function' then
    local hookOk, hookError = pcall(MZPolice.Restraints.onCustodyReleased, state, reason, options)
    if not hookOk then
      print(('[mz_police][custody] restraint release hook failed: %s'):format(tostring(hookError)))
    end
  end
  if state.escort then syncOfficer(state.escort.source, targetSource, false, revision) end
  syncTarget(targetSource, { revision = revision, cuffed = false }, reason)
  MZPolice.Audit.custodyCleanup(state.target, { revision = revision, reason = reason })
  return true
end

local function transition(actor, target, request, authorization, vehicleContext, transferOfficer, options)
  options = type(options) == 'table' and options or {}
  local state = states[target.source]
  local currentRevision = state and state.revision or 0
  if request.expectedRevision ~= currentRevision then
    return result(false, 'revision_conflict', { revision = currentRevision })
  end

  local oldEscort = state and state.escort or nil
  if state and request.action ~= 'cuff' and request.action ~= 'uncuff'
    and (not state.cuffedBy
      or state.cuffedBy.source ~= actor.source or state.cuffedBy.sessionId ~= actor.sessionId
      or state.cuffedBy.citizenid ~= actor.citizenid) then
    return result(false, 'custody_required', { revision = currentRevision })
  end
  if state and request.action == 'uncuff' and options.allowUncuff ~= true
    and (not state.cuffedBy
      or state.cuffedBy.source ~= actor.source or state.cuffedBy.sessionId ~= actor.sessionId
      or state.cuffedBy.citizenid ~= actor.citizenid) then
    return result(false, 'custody_required', { revision = currentRevision })
  end
  if request.action == 'cuff' then
    if state and state.cuffed then return result(false, 'already_cuffed', { revision = currentRevision }) end
    custodySequence = custodySequence + 1
    local restraint = copy(options.restraint)
    if type(restraint) ~= 'table' then restraint = {} end
    local origin = tostring(restraint.origin or 'service'):lower()
    if origin ~= 'service' and origin ~= 'physical' and origin ~= 'admin' then origin = 'service' end
    restraint.origin = origin
    restraint.actor = copy(actor)
    restraint.appliedAt = tonumber(restraint.appliedAt) or os.time()
    restraint.persistent = restraint.persistent == true
    state = {
      revision = currentRevision + 1,
      instanceId = ('%s:%s:%s'):format(
        tostring(target.sessionId or ''), tostring(target.characterId or ''), tostring(custodySequence)
      ),
      cuffed = true,
      target = copy(target),
      cuffedBy = copy(actor),
      restraint = restraint
    }
    states[target.source] = state
  elseif request.action == 'uncuff' then
    if not state or not state.cuffed then return result(false, 'not_cuffed', { revision = currentRevision }) end
    state.revision = currentRevision + 1
    state.restraint = type(state.restraint) == 'table' and state.restraint or {}
    state.restraint.settlement = copy(options.settlement)
    if MZPolice.Restraints and type(MZPolice.Restraints.onCustodyReleased) == 'function' then
      local hookOk, hookError = pcall(MZPolice.Restraints.onCustodyReleased, state, 'uncuff', {
        settlement = options.settlement,
        reason = options.reason,
        normalUncuff = true
      })
      if not hookOk then
        print(('[mz_police][custody] restraint uncuff hook failed: %s'):format(tostring(hookError)))
      end
    end
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
  elseif request.action == 'transfer' then
    if not state or not state.cuffed then return result(false, 'not_cuffed', { revision = currentRevision }) end
    if not transferOfficer then return result(false, 'transfer_officer_unauthorized', { revision = currentRevision }) end
    state.revision = currentRevision + 1
    state.cuffedBy = copy(transferOfficer)
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
    vehicleSeat = request.action ~= 'uncuff' and state.vehicle and state.vehicle.seat or nil,
    newOfficerSource = request.action == 'transfer' and transferOfficer.source or nil,
    restraint = request.action ~= 'uncuff' and publicRestraint(state) or nil
  })
  MZPolice.Audit.custody(request.action, actor, target, {
    orgCode = authorization.organization and authorization.organization.code or nil,
    capability = authorization.capability,
    requestId = request.requestId,
    revision = revision,
    result = response.code,
    origin = options.origin or (state.restraint and state.restraint.origin),
    reason = options.reason,
    newOfficerCitizenid = transferOfficer and transferOfficer.citizenid or nil
  })
  return response
end

local function execute(actorSource, payload, authorization, options)
  options = type(options) == 'table' and options or {}
  actorSource = tonumber(actorSource)
  if not actorSource or actorSource <= 0 then return result(false, 'invalid_source') end
  local request, requestErr = normalizeRequest(payload)
  if not request then return result(false, requestErr) end
  if request.targetSource == actorSource and options.allowSelf ~= true then
    return result(false, 'self_target_forbidden')
  end
  if not rateAllowed(actorSource) then return result(false, 'rate_limited') end

  local actor = authorization.identity
  local replayed = replay(actor, request)
  if replayed then return replayed end

  if targetLocks[request.targetSource] then return result(false, 'target_busy') end
  local lockKey = requestKey(actor, request.requestId)
  targetLocks[request.targetSource] = lockKey

  local response
  local ok, err = pcall(function()
    local target, identityErr = MZPolice.Bridge.resolveIdentity(request.targetSource)
    if not target then response = result(false, identityErr); return end
    local actorAlive, actorStateErr = alive(actorSource)
    if not actorAlive then response = result(false, actorStateErr); return end
    if options.allowDeadTarget ~= true then
      local targetAlive, targetStateErr = alive(request.targetSource, options.allowDownedTarget == true)
      if not targetAlive then response = result(false, targetStateErr); return end
    end
    local close, proximityErr = validateProximity(actorSource, request.targetSource, options.maximumDistance)
    if not close then response = result(false, proximityErr); return end
    local vehicleContext, transferOfficer
    if request.action == 'vehicle_put' then
      vehicleContext, proximityErr = resolvePutVehicle(actorSource, request.targetSource)
      if not vehicleContext then response = result(false, proximityErr); return end
    elseif request.action == 'vehicle_remove' then
      vehicleContext, proximityErr = resolveRemoveVehicle(request.targetSource)
      if not vehicleContext then response = result(false, proximityErr); return end
    elseif request.action == 'transfer' then
      if request.newOfficerSource == actorSource then response = result(false, 'transfer_target_invalid'); return end
      local transferAuthorization = MZPolice.Policy.authorizeDuty(request.newOfficerSource)
      if transferAuthorization.ok ~= true then
        response = result(false, 'transfer_officer_unauthorized'); return
      end
      local newOfficerAlive = alive(request.newOfficerSource)
      if not newOfficerAlive then response = result(false, 'transfer_officer_unauthorized'); return end
      local nearTarget, nearError = validateProximity(request.newOfficerSource, request.targetSource)
      if not nearTarget then response = result(false, nearError); return end
      local nearActor, actorNearError = validateProximity(actorSource, request.newOfficerSource)
      if not nearActor then response = result(false, actorNearError); return end
      transferOfficer = transferAuthorization.identity
    end
    response = transition(actor, target, request, authorization, vehicleContext, transferOfficer, options)
  end)

  targetLocks[request.targetSource] = nil
  if not ok then
    print(('[mz_police][custody] request failed safely: %s'):format(tostring(err)))
    response = result(false, 'internal_error')
  end
  remember(actor, request, response)
  return response
end

function Custody.request(actorSource, payload)
  actorSource = tonumber(actorSource)
  if not actorSource or actorSource <= 0 then return result(false, 'invalid_source') end
  local authorization = MZPolice.Policy.authorizeDuty(actorSource)
  if authorization.ok ~= true then return result(false, authorization.code) end
  local settings = restraintConfig()
  return execute(actorSource, payload, authorization, {
    origin = 'service',
    allowUncuff = settings.policeServiceUnlock ~= false,
    maximumDistance = MZPoliceConfig.Custody.maximumDistance
  })
end

function Custody.requestAuthorized(actorSource, payload, authorization, options)
  if type(authorization) ~= 'table' or type(authorization.identity) ~= 'table' then
    return result(false, 'authorization_unavailable')
  end
  authorization.ok = true
  authorization.organization = authorization.organization or { code = 'restraint', duty = true }
  return execute(actorSource, payload, authorization, options)
end

function Custody.get(targetSource)
  return copy(states[tonumber(targetSource)])
end

function Custody.getByCitizenId(citizenid)
  citizenid = tostring(citizenid or '')
  if citizenid == '' then return nil end
  for _, state in pairs(states) do
    if state.target and tostring(state.target.citizenid or '') == citizenid then
      return copy(state)
    end
  end
  return nil
end

function Custody.restore(targetSource, state)
  targetSource = tonumber(targetSource)
  if not targetSource or targetSource <= 0 or type(state) ~= 'table' or state.cuffed ~= true then
    return false, 'invalid_state'
  end
  local identity, identityError = MZPolice.Bridge.resolveIdentity(targetSource)
  if not identity then return false, identityError end
  if type(state.target) ~= 'table' or tostring(state.target.citizenid or '') ~= identity.citizenid then
    return false, 'identity_mismatch'
  end
  state.target = copy(identity)
  state.revision = math.max(1, tonumber(state.revision) or 1)
  state.cuffed = true
  states[targetSource] = copy(state)
  syncTarget(targetSource, states[targetSource], 'restored')
  return true
end

function Custody.setRestraint(targetSource, patch)
  local state = states[tonumber(targetSource)]
  if not state or type(patch) ~= 'table' then return false end
  state.restraint = type(state.restraint) == 'table' and state.restraint or {}
  for key, value in pairs(patch) do state.restraint[key] = copy(value) end
  state.revision = state.revision + 1
  syncTarget(targetSource, state, 'restraint_updated')
  return true
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

local function persistentPhysical(state)
  return state and state.restraint and state.restraint.origin == 'physical'
    and state.restraint.persistent == true
end

local function adminOrigin(state)
  return state and state.restraint and state.restraint.origin == 'admin'
end

function Custody.cleanupSource(source, reason)
  source = tonumber(source)
  if not source then return end
  rateLimits[source] = nil

  local targetState = states[source]
  if targetState then
    local keep = MZPolice.Restraints
      and type(MZPolice.Restraints.shouldPersistTargetOnDisconnect) == 'function'
      and MZPolice.Restraints.shouldPersistTargetOnDisconnect(targetState, reason)
    if keep then
      MZPolice.Restraints.suspendTargetState(targetState, reason)
      states[source] = nil
      setRestraintStateBag(source, nil)
    else
      releaseTarget(source, reason, { settleItems = true })
    end
  end

  local targets = {}
  for targetSource, state in pairs(states) do
    if (state.cuffedBy and state.cuffedBy.source == source)
      or (state.escort and state.escort.source == source) then
      targets[#targets + 1] = targetSource
    end
  end
  for _, targetSource in ipairs(targets) do
    local state = states[targetSource]
    if state then
      local actorMatch = state.cuffedBy and state.cuffedBy.source == source
      local keep = actorMatch and MZPolice.Restraints
        and type(MZPolice.Restraints.shouldPersistActorOnDisconnect) == 'function'
        and MZPolice.Restraints.shouldPersistActorOnDisconnect(state, reason)
      if keep then
        if state.escort and state.escort.source == source then
          state.escort = nil
          state.revision = state.revision + 1
          syncTarget(targetSource, state, 'actor_dropped')
        end
        state.restraint.actorOffline = true
        if type(MZPolice.Restraints.persistState) == 'function' then
          MZPolice.Restraints.persistState(state, 'actor_offline')
        end
      else
        releaseTarget(targetSource, reason, { settleItems = true })
      end
    end
  end
end

function Custody.sweep()
  local targets = {}
  for targetSource in pairs(states) do targets[#targets + 1] = targetSource end
  for _, targetSource in ipairs(targets) do
    local state = states[targetSource]
    local persistent = persistentPhysical(state)
    local admin = adminOrigin(state)
    local suspended = false
    local reason

    if not state or not identityMatches(state.target) then
      if persistent and MZPolice.Restraints
        and type(MZPolice.Restraints.suspendTargetState) == 'function' then
        MZPolice.Restraints.suspendTargetState(state, 'target_session_changed')
        states[targetSource] = nil
        setRestraintStateBag(targetSource, nil)
        suspended = true
      else
        reason = 'target_session_changed'
      end
    else
      local allowDowned = persistent or admin
        or (state.restraint and state.restraint.origin == 'physical')
      local targetAlive = alive(targetSource, allowDowned)
      if not targetAlive then reason = 'target_not_alive' end
    end

    if not suspended then
      if not reason and not persistent and not admin
        and (not state.cuffedBy or not identityMatches(state.cuffedBy)) then
        reason = 'actor_session_changed'
      end
      if not reason and not persistent and not admin
        and state.restraint and state.restraint.origin ~= 'physical' then
        local authorization = MZPolice.Policy.authorizeDuty(state.cuffedBy.source)
        if authorization.ok ~= true then reason = 'actor_authority_lost' end
      end
      if not reason and not persistent and not admin then
        local actorAlive = alive(state.cuffedBy.source)
        if not actorAlive then reason = 'actor_not_alive' end
      end
      if not reason and state.escort and not identityMatches(state.escort) then
        if persistent then
          state.escort = nil
          state.revision = state.revision + 1
          syncTarget(targetSource, state, 'escort_session_changed')
        else
          reason = 'escort_session_changed'
        end
      end
      if not reason and state.escort and not persistent then
        local escortAuthorization = MZPolice.Policy.authorizeDuty(state.escort.source)
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
      if reason then releaseTarget(targetSource, reason, { settleItems = true }) end
    end
  end
  if MZPolice.Search then MZPolice.Search.sweep() end
  if MZPolice.Stations then MZPolice.Stations.sweep() end
  if MZPolice.Enforcement then MZPolice.Enforcement.sweep() end
  if MZPolice.Evidence then MZPolice.Evidence.sweep() end
  if MZPolice.Advanced then MZPolice.Advanced.sweep() end
  if MZPolice.Restraints and type(MZPolice.Restraints.sweep) == 'function' then
    MZPolice.Restraints.sweep()
  end
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
  for _, targetSource in ipairs(targets) do
    local state = states[targetSource]
    local keep = persistentPhysical(state) and MZPolice.Restraints
      and type(MZPolice.Restraints.shouldKeepOnResourceStop) == 'function'
      and MZPolice.Restraints.shouldKeepOnResourceStop(state)
    if keep then
      MZPolice.Restraints.suspendTargetState(state, reason or 'resource_stop')
      states[targetSource] = nil
      setRestraintStateBag(targetSource, nil)
    else
      releaseTarget(targetSource, reason or 'resource_stop', { settleItems = true })
    end
  end
end

MZPolice.Custody = Custody
