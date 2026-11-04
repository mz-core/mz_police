MZPolice = MZPolice or {}

local Interactions = {}
local rateLimits = {}

local function result(ok, code, extra)
  local value = { ok = ok == true, code = tostring(code or '') }
  for key, entry in pairs(type(extra) == 'table' and extra or {}) do value[key] = entry end
  return value
end

local function closed(payload)
  if type(payload) ~= 'table' then return false end
  for key in pairs(payload) do if key ~= 'targetSource' then return false end end
  return true
end

local function rateAllowed(source)
  local now = GetGameTimer()
  local window = rateLimits[source]
  if not window or now - window.startedAt >= 5000 then
    rateLimits[source] = { startedAt = now, count = 1 }
    return true
  end
  window.count = window.count + 1
  return window.count <= 12
end

local function closeEnough(leftSource, rightSource)
  if type(GetPlayerRoutingBucket) == 'function'
    and tonumber(GetPlayerRoutingBucket(leftSource)) ~= tonumber(GetPlayerRoutingBucket(rightSource)) then
    return false, 'routing_bucket_mismatch'
  end
  if type(GetPlayerPed) ~= 'function' or type(GetEntityCoords) ~= 'function' then
    return false, 'position_unavailable'
  end
  local leftPed, rightPed = GetPlayerPed(leftSource), GetPlayerPed(rightSource)
  if not leftPed or leftPed == 0 or not rightPed or rightPed == 0 then return false, 'position_unavailable' end
  local left, right = GetEntityCoords(leftPed), GetEntityCoords(rightPed)
  local lx, ly, lz = left and tonumber(left.x or left[1]), left and tonumber(left.y or left[2]), left and tonumber(left.z or left[3])
  local rx, ry, rz = right and tonumber(right.x or right[1]), right and tonumber(right.y or right[2]), right and tonumber(right.z or right[3])
  if not lx or not ly or not lz or not rx or not ry or not rz then return false, 'position_unavailable' end
  local dx, dy, dz = lx - rx, ly - ry, lz - rz
  local maximum = math.max(tonumber(MZPoliceConfig.Custody.maximumDistance) or 2.5,
    tonumber(MZPoliceConfig.Prison.maximumDistance) or 3.0)
  return dx * dx + dy * dy + dz * dz <= maximum * maximum, 'target_too_far'
end

local function authorized(source, capability)
  local decision = MZPolice.Policy.authorize(source, capability)
  return decision.ok == true
end

local function target(source, payload)
  if not closed(payload) then return nil, 'invalid_payload' end
  local targetSource = tonumber(payload.targetSource)
  if not targetSource or targetSource <= 0 or targetSource == tonumber(source) then return nil, 'invalid_target' end
  if not rateAllowed(source) then return nil, 'rate_limited' end
  local close, proximityError = closeEnough(source, targetSource)
  if not close then return nil, proximityError end
  local identity, identityError = MZPolice.Bridge.resolveIdentity(targetSource)
  if not identity then return nil, identityError end
  return { source = targetSource, identity = identity }
end

function Interactions.context(source, payload)
  local access = MZPolice.Policy.authorizeDuty(source)
  if access.ok ~= true then return result(false, access.code) end
  local selected, targetError = target(source, payload)
  if not selected then return result(false, targetError) end

  local custody = MZPolice.Custody.get(selected.source)
  local cuffed = custody and custody.cuffed == true or false
  local escorted = cuffed and custody.escort ~= nil or false
  local inVehicle = cuffed and custody.vehicle ~= nil or false
  local arrestConfig = type(MZPoliceConfig.Arrest) == 'table' and MZPoliceConfig.Arrest or {}
  -- Custodia/target: organizacao autorizada + duty. O servidor ainda valida
  -- alvo, distancia, bucket, estado e custodia em cada acao.
  local canCustody = access.ok == true
  local canSearch = authorized(source, 'police.search')
  local canRead = authorized(source, MZPoliceConfig.Records.readCapability)
  local canArrest = authorized(source, arrestConfig.capability)
    and authorized(source, arrestConfig.writeCapability)
  local cuffedByMe = cuffed and custody and custody.cuffedBy
    and tonumber(custody.cuffedBy.source) == tonumber(source) or false
  local processing = cuffedByMe and canArrest and MZPolice.Prison.processingContext(source, selected.source) or nil

  return result(true, 'interaction_context', {
    targetSource = selected.source,
    revision = custody and tonumber(custody.revision) or 0,
    state = {
      cuffed = cuffed, escorted = escorted, inVehicle = inVehicle,
      processingPointId = processing and processing.pointId or nil
    },
    actions = {
      cuff = canCustody and not cuffed,
      uncuff = canCustody and cuffed,
      transfer = canCustody and cuffedByMe,
      escort_start = canCustody and cuffed and not escorted and not inVehicle,
      escort_stop = canCustody and cuffed and escorted,
      vehicle_put = canCustody and cuffed and not inVehicle,
      vehicle_remove = canCustody and cuffed and inVehicle,
      search = canSearch and cuffed,
      identify = canRead,
      open_mdt = canRead,
      quick_arrest = cuffedByMe and canArrest and arrestConfig.quickEnabled == true,
      process_arrest = processing ~= nil
    }
  })
end

function Interactions.identify(source, payload)
  local selected, targetError = target(source, payload)
  if not selected then return result(false, targetError) end
  local authorization = MZPolice.Policy.authorize(source, MZPoliceConfig.Records.readCapability)
  if authorization.ok ~= true then return result(false, authorization.code) end
  local character, characterError = MZPolice.Bridge.getCharacterByCitizenId(selected.identity.citizenid)
  if not character then return result(false, characterError) end
  return result(true, 'citizen_identified', {
    targetSource = selected.source,
    citizen = {
      citizenid = selected.identity.citizenid,
      firstname = character.firstname or character.firstName,
      lastname = character.lastname or character.lastName
    }
  })
end

function Interactions.openMdt(source, payload)
  local selected, targetError = target(source, payload)
  if not selected then return result(false, targetError) end
  local citizen = MZPolice.Records.getCitizen(source, { citizenid = selected.identity.citizenid })
  if citizen.ok ~= true then return citizen end
  citizen.targetSource = selected.source
  citizen.code = 'citizen_context_ready'
  return citizen
end

function Interactions.processArrest(source, payload)
  local selected, targetError = target(source, payload)
  if not selected then return result(false, targetError) end
  local arrestConfig = type(MZPoliceConfig.Arrest) == 'table' and MZPoliceConfig.Arrest or {}
  local write = MZPolice.Policy.authorize(source, arrestConfig.writeCapability)
  if write.ok ~= true then return result(false, write.code) end
  local arrest = MZPolice.Policy.authorize(source, arrestConfig.capability)
  if arrest.ok ~= true then return result(false, arrest.code) end
  local custody = MZPolice.Custody.get(selected.source)
  if not custody or custody.cuffed ~= true or not custody.cuffedBy
    or tonumber(custody.cuffedBy.source) ~= tonumber(source) then return result(false, 'custody_required') end
  local processing, processingError = MZPolice.Prison.processingContext(source, selected.source)
  if not processing then return result(false, processingError) end
  local citizen = MZPolice.Records.getCitizen(source, { citizenid = selected.identity.citizenid })
  if citizen.ok ~= true then return citizen end
  citizen.targetSource = selected.source
  citizen.processing = { pointId = processing.pointId }
  citizen.code = 'processing_context_ready'
  return citizen
end

function Interactions.cleanupSource(source)
  rateLimits[tonumber(source)] = nil
end

function Interactions.stop()
  rateLimits = {}
end

MZPolice.Interactions = Interactions
