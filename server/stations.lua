MZPolice = MZPolice or {}

local Stations = {}
local requestWindows = {}
local terminals = {}
local sourceLocks = {}

local OPEN_KEYS = { stationId = true }
local ISSUE_KEYS = { stationId = true, catalogKey = true, requestId = true }
local RETURN_KEYS = { stationId = true, instanceUid = true, requestId = true }

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

local function closedPayload(payload, allowed)
  if type(payload) ~= 'table' then return false end
  for field in pairs(payload) do if not allowed[field] then return false end end
  return true
end

local function rateAllowed(source)
  local config = MZPoliceConfig.Armory.rateLimit or {}
  local now = GetGameTimer()
  local windowMs = math.max(1000, tonumber(config.windowMs) or 5000)
  local maximum = math.max(1, math.floor(tonumber(config.maximum) or 6))
  local window = requestWindows[source]
  if not window or now - window.startedAt >= windowMs then
    requestWindows[source] = { startedAt = now, count = 1 }
    return true
  end
  window.count = window.count + 1
  return window.count <= maximum
end

local function station(stationId)
  stationId = key(stationId, 48)
  local value = stationId and MZPoliceConfig.Stations[stationId] or nil
  if type(value) ~= 'table' or value.enabled == false or type(value.armory) ~= 'table'
    or value.armory.enabled == false then
    return nil, 'station_not_configured'
  end
  local orgCode = key(value.orgCode, 64)
  local coords = value.armory.coords
  local x = coords and tonumber(coords.x or coords[1])
  local y = coords and tonumber(coords.y or coords[2])
  local z = coords and tonumber(coords.z or coords[3])
  if not orgCode or MZPoliceConfig.AuthorizedOrganizations[orgCode] ~= true or not x or not y or not z then
    return nil, 'station_invalid'
  end
  return {
    id = stationId,
    label = trim(value.label) ~= '' and trim(value.label):sub(1, 64) or stationId,
    orgCode = orgCode,
    coords = { x = x, y = y, z = z },
    distance = math.max(1.0, math.min(5.0, tonumber(value.armory.interactDistance)
      or tonumber(MZPoliceConfig.Armory.maximumDistance) or 2.5))
  }
end

local function near(source, configured)
  local ped = GetPlayerPed(source)
  if not ped or ped == 0 or (type(DoesEntityExist) == 'function' and not DoesEntityExist(ped)) then
    return false, 'position_unavailable'
  end
  local coords = GetEntityCoords(ped)
  if not coords then return false, 'position_unavailable' end
  local dx = tonumber(coords.x or coords[1]) - configured.coords.x
  local dy = tonumber(coords.y or coords[2]) - configured.coords.y
  local dz = tonumber(coords.z or coords[3]) - configured.coords.z
  if dx * dx + dy * dy + dz * dz > (configured.distance + 0.75) ^ 2 then
    return false, 'station_too_far'
  end
  return true
end

local function authorize(source, stationId, capability)
  local configured, err = station(stationId)
  if not configured then return nil, nil, err end
  local close, distanceErr = near(source, configured)
  if not close then return nil, configured, distanceErr end
  local decision = MZPolice.Policy.authorize(source, capability, { orgCode = configured.orgCode })
  if decision.ok ~= true then return nil, configured, decision.code end
  return decision, configured
end

local function catalogEntry(catalogKey)
  catalogKey = key(catalogKey, 48)
  local entry = catalogKey and MZPoliceConfig.Armory.catalog[catalogKey] or nil
  if type(entry) ~= 'table' then return nil, 'catalog_item_not_found' end
  local item = key(entry.item, 64)
  local capability = trim(entry.capability or MZPoliceConfig.Armory.capability):lower()
  if not item or capability == '' then return nil, 'catalog_item_invalid' end
  return {
    key = catalogKey,
    item = item,
    label = trim(entry.label) ~= '' and trim(entry.label):sub(1, 64) or item,
    capability = capability,
    minimumGrade = math.max(0, math.floor(tonumber(entry.minimumGrade) or 0))
  }
end

local function entryAllowed(source, decision, configured, entry)
  local grade = tonumber(decision.organization and decision.organization.grade and decision.organization.grade.level) or -1
  if grade < entry.minimumGrade then return false, 'grade_denied' end
  if entry.capability == MZPoliceConfig.Armory.capability then return true end
  local allowed, err = MZPolice.Bridge.canOrganization(source, configured.orgCode, entry.capability)
  if allowed == nil then return false, err or 'organization_unavailable' end
  return allowed == true, allowed == true and nil or 'capability_denied'
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
  if sourceLocks[source] then return { ok = false, code = 'operation_in_progress' } end
  sourceLocks[source] = true
  local ok, response = pcall(execute, requestId)
  sourceLocks[source] = nil
  if not ok then response = { ok = false, code = 'operation_failed' } end
  bucket[requestId] = { fingerprint = fingerprint, response = copy(response), createdAt = GetGameTimer() }
  return response
end

function Stations.openArmory(source, payload)
  if not closedPayload(payload, OPEN_KEYS) then return { ok = false, code = 'invalid_payload' } end
  if not rateAllowed(source) then return { ok = false, code = 'rate_limited' } end
  local decision, configured, err = authorize(source, payload.stationId, MZPoliceConfig.Armory.capability)
  if not decision then return { ok = false, code = err } end

  local catalog = {}
  for catalogKey in pairs(MZPoliceConfig.Armory.catalog or {}) do
    local entry = catalogEntry(catalogKey)
    if entry and entryAllowed(source, decision, configured, entry) then
      catalog[#catalog + 1] = entry
    end
  end
  table.sort(catalog, function(left, right) return left.key < right.key end)
  local issued, listErr = MZPolice.Bridge.listPoliceIssuedEquipment(source, configured.orgCode, configured.id)
  if not issued then return { ok = false, code = listErr } end
  return {
    ok = true,
    action = 'open',
    station = { id = configured.id, label = configured.label, orgCode = configured.orgCode },
    catalog = catalog,
    issued = issued
  }
end

function Stations.issue(source, payload)
  if not closedPayload(payload, ISSUE_KEYS) then return { ok = false, code = 'invalid_payload' } end
  if not rateAllowed(source) then return { ok = false, code = 'rate_limited' } end
  local stationId, catalogKey = key(payload.stationId, 48), key(payload.catalogKey, 48)
  return replay(source, payload.requestId, table.concat({ 'issue', stationId or '', catalogKey or '' }, ':'), function(requestId)
    local entry, entryErr = catalogEntry(catalogKey)
    if not entry then return { ok = false, code = entryErr } end
    local decision, configured, authErr = authorize(source, stationId, MZPoliceConfig.Armory.capability)
    if not decision then return { ok = false, code = authErr } end
    local allowed, allowedErr = entryAllowed(source, decision, configured, entry)
    if not allowed then return { ok = false, code = allowedErr } end
    local operationId = ('armory:%s:%s'):format(decision.identity.sessionId, requestId)
    local result, issueErr = MZPolice.Bridge.issuePoliceEquipment(
      source, configured.orgCode, configured.id, entry.key, entry.item, operationId
    )
    MZPolice.Audit.armory('issue', decision.identity, {
      orgCode = configured.orgCode, stationId = configured.id, operationId = operationId,
      catalogKey = entry.key, item = entry.item, result = result and 'issued' or 'denied', reason = issueErr
    })
    if not result then return { ok = false, code = issueErr } end
    return { ok = true, action = 'issue', code = 'equipment_issued', result = result }
  end)
end

function Stations.returnIssued(source, payload)
  if not closedPayload(payload, RETURN_KEYS) then return { ok = false, code = 'invalid_payload' } end
  if not rateAllowed(source) then return { ok = false, code = 'rate_limited' } end
  local stationId = key(payload.stationId, 48)
  local instanceUid = trim(payload.instanceUid)
  if instanceUid == '' or #instanceUid > 64 or not instanceUid:match('^[%w:_-]+$') then
    return { ok = false, code = 'invalid_instance_uid' }
  end
  return replay(source, payload.requestId, table.concat({ 'return', stationId or '', instanceUid }, ':'), function(requestId)
    local decision, configured, authErr = authorize(source, stationId, MZPoliceConfig.Armory.capability)
    if not decision then return { ok = false, code = authErr } end
    local operationId = ('armory:%s:%s'):format(decision.identity.sessionId, requestId)
    local result, returnErr = MZPolice.Bridge.returnPoliceEquipment(
      source, configured.orgCode, configured.id, instanceUid, operationId
    )
    MZPolice.Audit.armory('return', decision.identity, {
      orgCode = configured.orgCode, stationId = configured.id, operationId = operationId,
      instanceUid = instanceUid, result = result and 'returned' or 'denied', reason = returnErr
    })
    if not result then return { ok = false, code = returnErr } end
    return { ok = true, action = 'return', code = 'equipment_returned', result = result }
  end)
end

function Stations.cleanupSource(source)
  requestWindows[source], terminals[source], sourceLocks[source] = nil, nil, nil
end

function Stations.sweep()
  local cutoff = GetGameTimer() - (tonumber(MZPoliceConfig.Armory.requestRetentionMs) or 120000)
  for source, bucket in pairs(terminals) do
    for requestId, terminal in pairs(bucket) do
      if terminal.createdAt < cutoff then bucket[requestId] = nil end
    end
    if not next(bucket) then terminals[source] = nil end
  end
end

function Stations.configuredCount()
  local count = 0
  for stationId in pairs(MZPoliceConfig.Stations or {}) do if station(stationId) then count = count + 1 end end
  return count
end

MZPolice.Stations = Stations
