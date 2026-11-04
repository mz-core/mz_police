--[[
    mz_police - Tracker V2 (stream autorizado server -> cliente -> NUI).

    DESLIGADO por padrao (MZPoliceConfig.TrackerV2.Enabled = false).
    Com a flag OFF, nada deste arquivo roda em producao: nenhum thread,
    nenhum subscriber e nenhum evento.

    Autoridade:
      - viewer: MZPolice.Policy.authorize(source, police.tracker.view)
      - unidade: MZPolice.Policy.authorize(unitSource, police.tracker.use)
                 + mz_vehicles:PoliceResolveOccupiedVehicle
      - org/duty/capability: mz_org via policy existente
      - posicao: entidade server-side do mz_vehicles (OneSync)

    O cliente recebe somente deltas filtrados por org + routing bucket.
    Nao ha broadcast publico e nao ha FetchAllUnits no mz_navigation.
]]

MZPolice = MZPolice or {}
MZPolice.TrackerV2 = MZPolice.TrackerV2 or {}

local Tracker = MZPolice.TrackerV2

local Deps = nil
local Attached = false
local Started = false
local Subscribers = {}
local UnitCache = {}
local Generation = 0

local function cfg()
    local value = type(MZPoliceConfig) == 'table' and MZPoliceConfig.TrackerV2
    return type(value) == 'table' and value or {}
end

local function trackerCfg()
    return type(Deps) == 'table' and type(Deps.trackerConfig) == 'function'
        and Deps.trackerConfig() or {}
end

local function enabled()
    return cfg().Enabled == true
end

local function nowMs()
    return type(GetGameTimer) == 'function' and tonumber(GetGameTimer()) or 0
end

local function finite(value)
    return type(value) == 'number' and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function result(ok, code, extra)
    local out = { ok = ok == true, code = tostring(code or '') }
    for key, value in pairs(type(extra) == 'table' and extra or {}) do out[key] = value end
    return out
end

local function log(message)
    if cfg().Debug == true then
        print(('[mz_police][tracker_v2] %s'):format(tostring(message)))
    end
end

local function revisionOf(map)
    if type(map) ~= 'table' then return 0 end
    local hash = 0
    local function add(text)
        text = tostring(text or '')
        for index = 1, #text do
            hash = (hash * 31 + text:byte(index)) % 2147483647
        end
    end
    add(map.minZoom); add(map.maxZoom); add(map.defaultZoom)
    local bounds = type(map.bounds) == 'table' and map.bounds or {}
    add(bounds.minX); add(bounds.maxX); add(bounds.minY); add(bounds.maxY)
    for _, layer in ipairs(type(map.layers) == 'table' and map.layers or {}) do
        add(layer.id); add(layer.revision)
    end
    for _, poi in ipairs(type(map.pois) == 'table' and map.pois or {}) do
        add(poi.id); add(poi.revision)
    end
    return hash
end

local function fingerprint(unit)
    if type(unit) ~= 'table' then return '' end
    local function number(value)
        return finite(value) and string.format('%.2f', value) or ''
    end
    return table.concat({
        tostring(unit.id or ''),
        number(unit.x), number(unit.y), number(unit.z),
        number(unit.heading), tostring(unit.status or ''),
        tostring(unit.plate or '')
    }, '\30')
end

local function categoryForModel(model)
    local value = tostring(model or ''):lower()
    local patterns = {
        helicopter = { 'polmav', 'maverick', 'buzzard', 'frogger', 'supervolito', 'swift', 'havok', 'akula' },
        moto = { 'policeb', 'bati', 'akuma', 'sanchez', 'daemon', 'hakuchou', 'double', 'ruffian' },
        boat = { 'boat', 'dinghy', 'jetmax', 'squalo', 'tropic', 'marquis', 'seashark', 'toro', 'avisa' },
        plane = { 'plane', 'luxor', 'dodo', 'cuban', 'mallard', 'titan', 'lazer', 'stunt', 'nimbus' }
    }
    for category, list in pairs(patterns) do
        for _, pattern in ipairs(list) do
            if value:find(pattern, 1, true) then return category end
        end
    end
    return 'car'
end

local function idPart(value, fallback, maximum)
    local normalized = tostring(value or ''):gsub('[^%w_.%-]', '_'):sub(1, maximum or 96)
    return normalized ~= '' and normalized or fallback
end

local function unitIdFor(decision, vehicle, current)
    local plate = tostring(vehicle and vehicle.plate or '')
    local key = idPart(plate ~= '' and plate or (current and current.sessionId), 'unknown', 96)
    local org = idPart(decision and decision.organization and decision.organization.code, 'police', 48)
    return ('unit:%s:%s'):format(org, key), key
end

local function collectUnits(now)
    local units = {}
    if type(Deps) ~= 'table' or type(Deps.states) ~= 'table' then return units end
    local config = trackerCfg()
    local settings = cfg()
    local maxUnits = math.max(1, math.min(500, math.floor(tonumber(settings.MaxUnits) or 100)))
    local authTtl = math.max(500, math.floor(tonumber(settings.UnitAuthTtlMs) or 3000))
    local clock = os.time()

    for unitSource, current in pairs(Deps.states) do
        if #units >= maxUnits then break end
        local tracker = type(current) == 'table' and current.tracker or nil
        if type(tracker) == 'table' and clock < (tonumber(tracker.expiresAt) or 0) then
            local cache = UnitCache[unitSource]
            if not cache or now - (tonumber(cache.checkedAt) or 0) >= authTtl then
                local decision, code = Deps.authorize(unitSource, config.useCapability)
                cache = {
                    ok = decision ~= nil and Deps.sameActor(current, decision) == true,
                    code = code,
                    checkedAt = now,
                    decision = decision
                }
                UnitCache[unitSource] = cache
            end

            if cache.ok then
                -- O contexto do veiculo muda mais rapido que org/duty e precisa ser
                -- revalidado a cada amostra para guardar/trocar a viatura remover ja.
                local vehicle = Deps.occupiedVehicle(unitSource, config.vehicleModels)
                local valid = vehicle and Deps.modelAllowed(config.vehicleModels, vehicle)
                    and vehicle.plate == tracker.vehicle.plate
                if valid then
                    local entity = type(NetworkGetEntityFromNetworkId) == 'function'
                        and NetworkGetEntityFromNetworkId(vehicle.networkId) or 0
                    local coordinates = entity and entity ~= 0 and GetEntityCoords(entity) or nil
                    local x = coordinates and tonumber(coordinates.x)
                    local y = coordinates and tonumber(coordinates.y)
                    local z = coordinates and tonumber(coordinates.z)
                    if finite(x) and finite(y) then
                        local id, unitId = unitIdFor(cache.decision, vehicle, current)
                        local unit = {
                            id = id,
                            unitId = unitId,
                            plate = tostring(vehicle.plate or ''),
                            orgCode = tostring(cache.decision.organization.code or 'police'),
                            x = x + 0.0,
                            y = y + 0.0,
                            z = finite(z) and (z + 0.0) or nil,
                            heading = type(GetEntityHeading) == 'function'
                                and (tonumber(GetEntityHeading(entity)) or 0) or 0,
                            sampleTs = now,
                            status = 'active',
                            category = categoryForModel(vehicle.model),
                            label = ('Unidade %s'):format(tostring(vehicle.plate or unitId)),
                            routingBucket = tonumber(vehicle.routingBucket) or 0
                        }
                        units[#units + 1] = unit
                    end
                else
                    if type(Deps.clearTracker) == 'function' then Deps.clearTracker(unitSource) end
                    UnitCache[unitSource] = nil
                end
            else
                if type(Deps.clearTracker) == 'function' then Deps.clearTracker(unitSource) end
            end
        else
            UnitCache[unitSource] = nil
        end
    end
    return units
end

local function sendReset(source, subscriber, reason)
    if not subscriber then return end
    local ok = pcall(TriggerClientEvent, 'mz_police:client:tracker:reset', source, {
        version = 1,
        layer = 'police-units',
        generation = subscriber.generation,
        reason = tostring(reason or 'reset'),
        serverTs = nowMs()
    })
    if not ok then log(('reset failed source=%s'):format(tostring(source))) end
end

local function removeSubscriber(source, reason)
    local subscriber = Subscribers[source]
    if not subscriber then return false end
    Subscribers[source] = nil
    sendReset(source, subscriber, reason)
    return true
end

local function viewerAllowed(source, subscriber, now, force)
    local settings = cfg()
    local ttl = math.max(500, math.floor(tonumber(settings.ViewerAuthTtlMs) or 3000))
    if force or not subscriber.viewer or now - (tonumber(subscriber.viewerCheckedAt) or 0) >= ttl then
        local viewer, code = Deps.authorize(source, trackerCfg().viewCapability)
        if not viewer then
            return nil, code or 'capability_denied'
        end
        subscriber.viewer = viewer
        subscriber.viewerCheckedAt = now
    end
    subscriber.viewerBucket = type(GetPlayerRoutingBucket) == 'function'
        and (tonumber(GetPlayerRoutingBucket(source)) or 0) or 0
    return subscriber.viewer
end

local function buildDelta(source, subscriber, now, opts, collectedUnits)
    local viewer, viewerError = viewerAllowed(source, subscriber, now, opts and opts.forceViewer)
    if not viewer then
        removeSubscriber(source, viewerError or 'unauthorized')
        return false
    end

    local units = collectedUnits or collectUnits(now)
    local viewerOrg = tostring(viewer.organization and viewer.organization.code or '')
    local viewerBucket = tonumber(subscriber.viewerBucket) or 0
    local current, upserts, aliveIds = {}, {}, {}
    for _, unit in ipairs(units) do
        if unit.orgCode == viewerOrg and (tonumber(unit.routingBucket) or 0) == viewerBucket then
            current[unit.id] = fingerprint(unit)
            aliveIds[#aliveIds + 1] = unit.id
            if subscriber.lastUnits[unit.id] ~= current[unit.id] then
                upserts[#upserts + 1] = unit
            end
        end
    end

    local removedIds = {}
    for id in pairs(subscriber.lastUnits) do
        if current[id] == nil then removedIds[#removedIds + 1] = id end
    end

    subscriber.seq = subscriber.seq + 1
    local settings = cfg()
    local delta = {
        version = 1,
        layer = 'police-units',
        generation = subscriber.generation,
        seq = subscriber.seq,
        serverTs = now,
        tickMs = math.max(250, math.floor(tonumber(settings.TickMs) or 1000)),
        staleAfterMs = math.max(1000, math.floor(tonumber(settings.StaleAfterMs) or 5000)),
        upserts = upserts,
        removedIds = removedIds,
        aliveIds = aliveIds,
        broadcasting = Deps.publicState(source).tracker == true
    }

    local requestMap = opts and opts.requestMap == true
    local mapTtl = math.max(5000, math.floor(tonumber(settings.MapCacheMs) or 60000))
    if requestMap or (subscriber.mapSentAt or 0) == 0 or now - (subscriber.mapSentAt or 0) >= mapTtl then
        local map, mapError = Deps.navigationMap(source)
        if type(map) == 'table' then
            delta.map = map
            delta.mapRevision = revisionOf(map)
            subscriber.mapSentAt = now
        else
            delta.mapError = tostring(mapError or 'navigation_unavailable')
            subscriber.mapSentAt = now - mapTtl + math.min(mapTtl, 5000)
        end
    end

    subscriber.lastUnits = current
    subscriber.lastSendAt = now
    local ok, err = pcall(TriggerClientEvent, 'mz_police:client:tracker:delta', source, delta)
    if not ok then
        log(('delta failed source=%s error=%s'):format(tostring(source), tostring(err)))
        removeSubscriber(source, 'transport_error')
        return false
    end
    return true
end

function Tracker.Attach(deps)
    if Attached then return true end
    if type(deps) ~= 'table' then return false end
    Deps = deps
    Attached = true
    if enabled() then Tracker.Start() end
    return true
end

function Tracker.IsEnabled()
    return enabled()
end

function Tracker.Start()
    if Started or not enabled() or not Attached then return false end
    Started = true
    if type(CreateThread) ~= 'function' or type(Wait) ~= 'function' then return true end
    CreateThread(function()
        while Started do
            Wait(math.max(250, math.floor(tonumber(cfg().TickMs) or 1000)))
            local ok, err = pcall(Tracker.Tick)
            if not ok then log(('tick failed: %s'):format(tostring(err))) end
        end
    end)
    return true
end

function Tracker.Subscribe(source, payload)
    if not enabled() then return result(false, 'tracker_v2_disabled') end
    if not Attached or type(Deps) ~= 'table' then return result(false, 'tracker_v2_unavailable') end
    source = tonumber(source)
    if not source or source <= 0 then return result(false, 'invalid_source') end
    payload = type(payload) == 'table' and payload or {}
    local now = nowMs()

    local viewer, code = Deps.authorize(source, trackerCfg().viewCapability)
    if not viewer then return result(false, code or 'capability_denied') end

    local subscriber = Subscribers[source]
    if not subscriber then
        Generation = Generation + 1
        subscriber = {
            generation = Generation,
            seq = 0,
            viewer = viewer,
            viewerCheckedAt = now,
            viewerBucket = type(GetPlayerRoutingBucket) == 'function'
                and (tonumber(GetPlayerRoutingBucket(source)) or 0) or 0,
            lastUnits = {},
            mapSentAt = 0,
            lastSendAt = 0
        }
        Subscribers[source] = subscriber
    else
        subscriber.viewer = viewer
        subscriber.viewerCheckedAt = now
    end

    local sent = buildDelta(source, subscriber, now, {
        requestMap = payload.requestMap == true,
        forceViewer = true
    })
    if not sent then return result(false, 'tracker_unavailable') end
    return result(true, 'tracker_subscribed', {
        generation = subscriber.generation,
        seq = subscriber.seq,
        tickMs = math.max(250, math.floor(tonumber(cfg().TickMs) or 1000)),
        staleAfterMs = math.max(1000, math.floor(tonumber(cfg().StaleAfterMs) or 5000))
    })
end

function Tracker.Unsubscribe(source)
    source = tonumber(source)
    if not source or source <= 0 then return result(false, 'invalid_source') end
    local removed = removeSubscriber(source, 'unsubscribed')
    return result(removed == true, removed and 'tracker_unsubscribed' or 'not_subscribed')
end

function Tracker.Revalidate(source)
    source = tonumber(source)
    if source then
        UnitCache[source] = nil
        local subscriber = Subscribers[source]
        if subscriber then subscriber.viewerCheckedAt = 0 end
        return true
    end
    UnitCache = {}
    for _, subscriber in pairs(Subscribers) do
        subscriber.viewerCheckedAt = 0
    end
    return true
end

function Tracker.RemoveSource(source)
    source = tonumber(source)
    if not source then return false end
    Subscribers[source] = nil
    UnitCache[source] = nil
    return true
end

function Tracker.Stop()
    for source, subscriber in pairs(Subscribers) do
        sendReset(source, subscriber, 'resource_stop')
    end
    Subscribers = {}
    UnitCache = {}
    Started = false
    Attached = false
    Deps = nil
    return true
end

function Tracker.Tick(now)
    if not enabled() or not Attached then return 0 end
    now = tonumber(now) or nowMs()
    if next(Subscribers) == nil then
        UnitCache = {}
        return 0
    end
    local count = 0
    local units = collectUnits(now)
    local snapshot = {}
    for source, subscriber in pairs(Subscribers) do snapshot[#snapshot + 1] = { source, subscriber } end
    for _, entry in ipairs(snapshot) do
        local source, subscriber = entry[1], entry[2]
        if Subscribers[source] == subscriber then
            local ok, sent = pcall(buildDelta, source, subscriber, now, nil, units)
            if ok and sent == true then count = count + 1 end
        end
    end
    return count
end

function Tracker.Diagnostics()
    local subscribers, units = 0, 0
    for _ in pairs(Subscribers) do subscribers = subscribers + 1 end
    for _ in pairs(UnitCache) do units = units + 1 end
    return {
        enabled = enabled(),
        attached = Attached,
        started = Started,
        subscribers = subscribers,
        unitCache = units,
        generation = Generation,
        tickMs = math.max(250, math.floor(tonumber(cfg().TickMs) or 1000))
    }
end

return Tracker
