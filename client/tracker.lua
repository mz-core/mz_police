--[[
    mz_police - consumidor client-side do Tracker V2.

    Uma unica assinatura server -> cliente alimenta:
      - a NUI do MDT (mdt:tracker:*);
      - os blips nativos (visao auxiliar interpolada).

    A flag MZPoliceConfig.TrackerV2.Enabled e OFF por padrao. Quando OFF,
    este modulo nao assina, nao cria blips e nao envia mensagens; o tracker
    antigo (client/advanced.lua) continua funcionando.
]]

MZPoliceClient = MZPoliceClient or {}
MZPoliceClient.Tracker = MZPoliceClient.Tracker or {}

local Tracker = MZPoliceClient.Tracker

local subscribed = false
local mdtActive = false
local nativeVisible = false
local generation = -1
local lastSeq = -1
local units = {}
local nativeTargets = {}
local nativeThread = false
local lastDeltaAt = 0
local tickMs = 1000
local staleAfterMs = 5000
local teleportThreshold = 250.0
local nativeIntervalMs = 150
local requestCounter = 0

local ALLOWED_CATEGORIES = {
    car = true, moto = true, helicopter = true, boat = true, plane = true, generic = true
}
local ALLOWED_STATUS = { active = true, stale = true, offduty = true }

local function cfg()
    local value = type(MZPoliceConfig) == 'table' and MZPoliceConfig.TrackerV2
    return type(value) == 'table' and value or {}
end

local function isEnabled()
    return cfg().Enabled == true
end

local function finite(value)
    return type(value) == 'number' and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function nowMs()
    return type(GetGameTimer) == 'function' and tonumber(GetGameTimer()) or 0
end

local function notify(message, kind)
    if type(MZPoliceClient.Notify) == 'function' then
        MZPoliceClient.Notify(message, kind or 'error', 'Rastreamento')
    else
        print(('[mz_police][tracker] %s'):format(tostring(message)))
    end
end

local function sendNui(messageType, payload)
    if type(SendNUIMessage) ~= 'function' then return end
    payload = type(payload) == 'table' and payload or {}
    payload.type = messageType
    pcall(SendNUIMessage, payload)
end

local function text(value, maximum)
    if type(value) ~= 'string' then return '' end
    return value:gsub('%c', ''):sub(1, maximum or 80)
end

local function normalizeUnit(raw)
    if type(raw) ~= 'table' then return nil end
    local id = type(raw.id) == 'string' and raw.id or ''
    if #id < 6 or #id > 160 or not id:match('^unit:[%w_%-%.]+:[%w_%-%.]+$') then return nil end
    local x, y = tonumber(raw.x), tonumber(raw.y)
    if not finite(x) or not finite(y) then return nil end
    local z = tonumber(raw.z)
    local heading = tonumber(raw.heading) or 0
    if heading ~= heading then heading = 0 end
    heading = heading % 360.0
    local category = ALLOWED_CATEGORIES[tostring(raw.category or '')] and tostring(raw.category) or 'generic'
    local status = ALLOWED_STATUS[tostring(raw.status or '')] and tostring(raw.status) or 'active'
    return {
        id = id,
        unitId = text(raw.unitId or raw.plate, 48),
        plate = text(raw.plate, 16),
        orgCode = text(raw.orgCode, 48),
        x = x + 0.0,
        y = y + 0.0,
        z = finite(z) and (z + 0.0) or nil,
        heading = heading + 0.0,
        sampleTs = tonumber(raw.sampleTs) or 0,
        status = status,
        category = category,
        label = text(raw.label, 80)
    }
end

local function removeNative(id)
    local target = nativeTargets[id]
    if not target then return end
    nativeTargets[id] = nil
    if target.blip and DoesBlipExist(target.blip) then RemoveBlip(target.blip) end
end

local function removeAllNative()
    for id in pairs(nativeTargets) do removeNative(id) end
end

local function ensureBlip(unit)
    local blip = AddBlipForCoord(unit.x, unit.y, unit.z or 0.0)
    SetBlipSprite(blip, 56)
    SetBlipColour(blip, 3)
    SetBlipScale(blip, 0.78)
    SetBlipAsShortRange(blip, false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(('Unidade %s'):format(unit.plate ~= '' and unit.plate or unit.unitId))
    EndTextCommandSetBlipName(blip)
    return blip
end

local function shortestDelta(from, to)
    return ((to - from + 540.0) % 360.0) - 180.0
end

local function updateNativeTarget(unit, now)
    local target = nativeTargets[unit.id]
    if not target or not DoesBlipExist(target.blip) then
        target = {
            blip = ensureBlip(unit),
            fromX = unit.x, fromY = unit.y, fromZ = unit.z or 0.0,
            toX = unit.x, toY = unit.y, toZ = unit.z or 0.0,
            fromHeading = unit.heading, toHeading = unit.heading
        }
        nativeTargets[unit.id] = target
    else
        target.fromX = target.toX or unit.x
        target.fromY = target.toY or unit.y
        target.fromZ = target.toZ or (unit.z or 0.0)
        target.fromHeading = target.toHeading or unit.heading
        target.toX = unit.x
        target.toY = unit.y
        target.toZ = unit.z or 0.0
        target.toHeading = unit.heading
    end

    local dx, dy = target.toX - target.fromX, target.toY - target.fromY
    local distance = math.sqrt(dx * dx + dy * dy)
    if distance > teleportThreshold then
        target.fromX, target.fromY, target.fromZ = target.toX, target.toY, target.toZ
        target.fromHeading = target.toHeading
    end

    target.startAt = now
    target.duration = math.max(100, math.min(2000, tickMs))
    target.lastSeenAt = now
    target.status = unit.status
    target.unit = unit
end

local function startNativeThread()
    if nativeThread or not isEnabled() or not nativeVisible or next(nativeTargets) == nil then return end
    nativeThread = true
    CreateThread(function()
        while nativeThread do
            Wait(math.max(50, math.floor(tonumber(nativeIntervalMs) or 150)))
            local now = nowMs()
            local any = false
            for id, target in pairs(nativeTargets) do
                any = true
                if not target.blip or not DoesBlipExist(target.blip) then
                    nativeTargets[id] = nil
                else
                    local age = now - (target.lastSeenAt or now)
                    if age > staleAfterMs then
                        SetBlipCoords(target.blip, target.toX, target.toY, target.toZ)
                        SetBlipAlpha(target.blip, 120)
                    else
                        local duration = math.max(1, target.duration or tickMs)
                        local progress = math.min(1.0, math.max(0.0, (now - (target.startAt or now)) / duration))
                        local x = target.fromX + (target.toX - target.fromX) * progress
                        local y = target.fromY + (target.toY - target.fromY) * progress
                        local z = target.fromZ + (target.toZ - target.fromZ) * progress
                        local heading = target.fromHeading + shortestDelta(target.fromHeading, target.toHeading) * progress
                        SetBlipCoords(target.blip, x, y, z)
                        SetBlipRotation(target.blip, math.floor(heading + 0.5) % 360)
                        SetBlipAlpha(target.blip, 255)
                    end
                end
            end
            if not any or not nativeVisible or not subscribed then nativeThread = false end
        end
    end)
end

local function clearClientState()
    units = {}
    removeAllNative()
    generation = -1
    lastSeq = -1
    lastDeltaAt = 0
end

local function requestIdFor(action)
    requestCounter = requestCounter + 1
    return ('tracker_v2:%s:%s'):format(tostring(action), tostring(requestCounter))
end

local function subscribe()
    if not isEnabled() or subscribed then return false end
    subscribed = true
    clearClientState()
    lastDeltaAt = nowMs()
    sendNui('mdt:tracker:reset', { reason = 'connecting' })
    TriggerServerEvent('mz_police:server:advanced:request', {
        action = 'trackerSubscribe',
        requestId = requestIdFor('subscribe'),
        payload = { requestMap = true }
    })
    local expectedGeneration = generation
    SetTimeout(5000, function()
        if subscribed and generation == expectedGeneration and generation < 0 then
            TriggerServerEvent('mz_police:server:advanced:request', {
                action = 'trackerUnsubscribe',
                requestId = requestIdFor('timeout'),
                payload = {}
            })
            subscribed = false
            clearClientState()
            sendNui('mdt:tracker:reset', { reason = 'timeout' })
            notify('Rastreamento indisponível: timeout de assinatura.', 'error')
        end
    end)
    return true
end

local function unsubscribe(sendServer)
    if not subscribed then return false end
    subscribed = false
    clearClientState()
    sendNui('mdt:tracker:reset', { reason = 'unsubscribed' })
    if sendServer ~= false then
        TriggerServerEvent('mz_police:server:advanced:request', {
            action = 'trackerUnsubscribe',
            requestId = requestIdFor('unsubscribe'),
            payload = {}
        })
    end
    return true
end

local function handleDelta(delta)
    if not isEnabled() or not subscribed then return end
    if type(delta) ~= 'table' or delta.version ~= 1 or delta.layer ~= 'police-units' then return end

    local nextGeneration = tonumber(delta.generation)
    local seq = tonumber(delta.seq)
    if not nextGeneration or not seq or seq % 1 ~= 0 then return end
    if generation >= 0 and nextGeneration < generation then return end
    if nextGeneration ~= generation then
        generation = nextGeneration
        lastSeq = -1
        units = {}
        removeAllNative()
    end
    if seq <= lastSeq then return end
    lastSeq = seq

    local now = nowMs()
    lastDeltaAt = now
    tickMs = math.max(250, math.min(10000, tonumber(delta.tickMs) or tickMs))
    staleAfterMs = math.max(1000, math.min(60000, tonumber(delta.staleAfterMs) or staleAfterMs))
    teleportThreshold = math.max(10.0, tonumber((cfg().TeleportThreshold)) or teleportThreshold)
    nativeIntervalMs = math.max(50, math.min(1000, tonumber(cfg().NativeIntervalMs) or nativeIntervalMs))

    local removed = type(delta.removedIds) == 'table' and delta.removedIds or {}
    for _, id in ipairs(removed) do
        if type(id) == 'string' then
            units[id] = nil
            removeNative(id)
        end
    end

    local upserts = type(delta.upserts) == 'table' and delta.upserts or {}
    local nuiUpserts = {}
    for _, raw in ipairs(upserts) do
        local unit = normalizeUnit(raw)
        if unit then
            units[unit.id] = unit
            if nativeVisible then updateNativeTarget(unit, now) end
            nuiUpserts[#nuiUpserts + 1] = unit
        end
    end

    local alive = type(delta.aliveIds) == 'table' and delta.aliveIds or {}
    for _, id in ipairs(alive) do
        if type(id) == 'string' then
            local target = nativeTargets[id]
            if target then target.lastSeenAt = now end
        end
    end

    sendNui('mdt:tracker:delta', {
        version = 1,
        layer = 'police-units',
        generation = generation,
        seq = seq,
        serverTs = tonumber(delta.serverTs) or 0,
        tickMs = tickMs,
        staleAfterMs = staleAfterMs,
        teleportThreshold = teleportThreshold,
        upserts = nuiUpserts,
        removedIds = removed,
        aliveIds = alive,
        broadcasting = delta.broadcasting == true,
        map = type(delta.map) == 'table' and delta.map or nil,
        mapRevision = delta.mapRevision,
        mapError = delta.mapError
    })
    startNativeThread()
end

local function handleReset(reset)
    reset = type(reset) == 'table' and reset or {}
    local reason = tostring(reset.reason or 'reset')
    subscribed = false
    clearClientState()
    sendNui('mdt:tracker:reset', { reason = reason, serverTs = tonumber(reset.serverTs) or 0 })
    if reason ~= 'unsubscribed' and reason ~= 'resource_stop' then
        notify(('Rastreamento encerrado: %s.'):format(reason), 'error')
    end
end

RegisterNetEvent('mz_police:client:tracker:delta', handleDelta)
RegisterNetEvent('mz_police:client:tracker:reset', handleReset)

RegisterNetEvent('mz_police:client:advanced:response', function(envelope)
    envelope = type(envelope) == 'table' and envelope or {}
    if tostring(envelope.action or '') ~= 'trackerSubscribe' then return end
    local response = type(envelope.response) == 'table' and envelope.response or {}
    if response.ok == true then return end
    subscribed = false
    clearClientState()
    sendNui('mdt:tracker:reset', { reason = tostring(response.code or 'unauthorized') })
    notify(('Rastreamento negado: %s.'):format(tostring(response.code or 'unauthorized')), 'error')
end)

RegisterNetEvent('mz_org:client:organizationsChanged', function()
    if isEnabled() then
        TriggerServerEvent('mz_police:server:advanced:request', {
            action = 'trackerRevalidate',
            requestId = requestIdFor('revalidate'),
            payload = {}
        })
    end
end)

RegisterNetEvent('mz_core:client:playerLoaded', function()
    Tracker.Stop()
end)

RegisterNetEvent('mz_core:client:characterSelectionRequired', function()
    Tracker.Stop()
end)

AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    Tracker.Stop()
end)

function Tracker.IsEnabled()
    return isEnabled()
end

function Tracker.IsSubscribed()
    return subscribed == true
end

function Tracker.SetMdtActive(active)
    if not isEnabled() then return false end
    mdtActive = active == true
    if mdtActive then
        subscribe()
    elseif not nativeVisible then
        unsubscribe()
    end
    return true
end

function Tracker.SetNativeVisible(visible)
    if not isEnabled() then return false end
    nativeVisible = visible == true
    if nativeVisible then
        subscribe()
        local now = nowMs()
        for _, unit in pairs(units) do updateNativeTarget(unit, now) end
        startNativeThread()
    else
        removeAllNative()
        if not mdtActive then unsubscribe() end
    end
    return true
end

function Tracker.Revalidate()
    if not isEnabled() then return false end
    TriggerServerEvent('mz_police:server:advanced:request', {
        action = 'trackerRevalidate',
        requestId = requestIdFor('revalidate'),
        payload = {}
    })
    return true
end

function Tracker.Stop()
    nativeVisible = false
    mdtActive = false
    nativeThread = false
    if subscribed then unsubscribe(true) end
    clearClientState()
    sendNui('mdt:tracker:reset', { reason = 'stopped' })
    return true
end

function Tracker.Diagnostics()
    local unitCount, nativeCount = 0, 0
    for _ in pairs(units) do unitCount = unitCount + 1 end
    for _ in pairs(nativeTargets) do nativeCount = nativeCount + 1 end
    return {
        enabled = isEnabled(),
        subscribed = subscribed,
        mdtActive = mdtActive,
        nativeVisible = nativeVisible,
        generation = generation,
        seq = lastSeq,
        units = unitCount,
        nativeTargets = nativeCount,
        lastDeltaAt = lastDeltaAt
    }
end

return Tracker
