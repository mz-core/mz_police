MZPoliceClient = MZPoliceClient or {}

local state = { bodycam = false, dashcam = false, flir = false, tracker = false }
local pending, sequence, cctvCamera = {}, 0, nil
local toggle
local trackerViewing, trackerRefreshMs, trackerBlips = false, 3000, {}
local heartbeatScheduled = false

local function trackerV2Enabled()
  return MZPoliceClient.Tracker and MZPoliceClient.Tracker.IsEnabled() == true
end

local messages = {
  advanced_cameras_disabled = 'Sistemas de câmera avançados estão desativados.',
  air_support_disabled = 'Suporte aéreo está desativado.',
  tracker_disabled = 'Rastreamento de unidades está desativado.',
  forensics_disabled = 'Perícia está desativada.',
  vehicle_required = 'Entre em uma viatura autorizada.',
  vehicle_not_authorized = 'Esta viatura não está autorizada para o equipamento.',
  flir_camera_not_configured = 'O offset da câmera aérea não foi configurado.',
  cctv_not_configured = 'A câmera fixa não possui configuração operacional.',
  capability_denied = 'Você não possui a permissão necessária.',
  duty_required = 'Você precisa estar em serviço.',
  rate_limited = 'Aguarde antes de tentar novamente.'
}

local function notify(message, kind)
  if type(MZPoliceClient.Notify) == 'function' then
    MZPoliceClient.Notify(message, kind, 'Sistemas policiais')
  else
    print(('[mz_police] %s'):format(tostring(message)))
  end
end

local function request(action, payload, callback)
  sequence = sequence + 1
  local requestId = ('advanced:%s:%s'):format(GetGameTimer(), sequence)
  pending[requestId] = callback
  TriggerServerEvent('mz_police:server:advanced:request', {
    action = action, requestId = requestId, payload = type(payload) == 'table' and payload or {}
  })
end

local function removeTrackerBlips()
  for unitId, entry in pairs(trackerBlips) do
    if entry.blip and DoesBlipExist(entry.blip) then RemoveBlip(entry.blip) end
    trackerBlips[unitId] = nil
  end
end

local function stopFlir()
  SetSeethrough(false)
  local heli = MZPoliceClient.Heli
  if type(heli) == 'table' and type(heli.Stop) == 'function' then heli.Stop() end
end

local function stopCctv()
  if cctvCamera then
    RenderScriptCams(false, false, 0, true, true)
    DestroyCam(cctvCamera, false)
    cctvCamera = nil
    ClearFocus()
  end
end

local function applyState(nextState)
  nextState = type(nextState) == 'table' and nextState or {}
  state.bodycam = nextState.bodycam == true
  state.dashcam = nextState.dashcam == true
  state.flir = nextState.flir == true
  state.tracker = nextState.tracker == true
  state.dashcamVehicle = nextState.dashcamVehicle
  if not state.flir then stopFlir() end
end

local function startFlir(camera)
  stopCctv()
  local heli = MZPoliceClient.Heli
  if type(heli) ~= 'table' or type(heli.Start) ~= 'function' then
    notify('O módulo da câmera aérea não está disponível.', 'error')
    toggle('flirToggle', 'flir', false)
    return
  end
  local ok, reason = heli.Start(camera)
  if ok ~= true then
    notify(reason or 'A câmera aérea não pôde ser iniciada.', 'error')
    toggle('flirToggle', 'flir', false)
  end
end

local function openCctv(camera, expiresAt)
  stopFlir()
  stopCctv()
  local coords, rotation = camera.coordinates or {}, camera.rotation or {}
  cctvCamera = CreateCamWithParams(
    'DEFAULT_SCRIPTED_CAMERA', tonumber(coords.x), tonumber(coords.y), tonumber(coords.z),
    tonumber(rotation.x), tonumber(rotation.y), tonumber(rotation.z), tonumber(camera.fov) or 45.0, true, 2
  )
  SetFocusPosAndVel(tonumber(coords.x), tonumber(coords.y), tonumber(coords.z), 0.0, 0.0, 0.0)
  SetCamActive(cctvCamera, true)
  RenderScriptCams(true, false, 0, true, true)
  local openedCamera = cctvCamera
  SetTimeout(math.max(1, (tonumber(expiresAt) or os.time() + 1) - os.time()) * 1000, function()
    if cctvCamera == openedCamera then stopCctv() end
  end)
  CreateThread(function()
    while cctvCamera do
      Wait(0)
      DisableControlAction(0, 24, true)
      DisableControlAction(0, 25, true)
      if IsControlJustReleased(0, 177) or IsControlJustReleased(0, 200) then stopCctv() end
    end
  end)
end

local function scheduleHeartbeat()
  if heartbeatScheduled or not (state.bodycam or state.dashcam or state.flir or state.tracker) then return end
  heartbeatScheduled = true
  SetTimeout(5000, function()
    heartbeatScheduled = false
    if not (state.bodycam or state.dashcam or state.flir or state.tracker) then return end
    request('heartbeat', {
      bodycam = state.bodycam, dashcam = state.dashcam, flir = state.flir, tracker = state.tracker
    }, function(response)
      if response.ok == true then applyState(response.state) else applyState({}) end
      scheduleHeartbeat()
    end)
  end)
end

local function applyTrackerSnapshot(response)
  local seen, now = {}, GetGameTimer()
  trackerRefreshMs = math.max(2000, tonumber(response.refreshMs) or 3000)
  for _, unit in ipairs(type(response.units) == 'table' and response.units or {}) do
    local unitId, coords = tostring(unit.unitId or ''), unit.coordinates or {}
    if unitId ~= '' and tonumber(coords.x) and tonumber(coords.y) and tonumber(coords.z) then
      seen[unitId] = true
      local entry = trackerBlips[unitId]
      if not entry or not DoesBlipExist(entry.blip) then
        local blip = AddBlipForCoord(tonumber(coords.x), tonumber(coords.y), tonumber(coords.z))
        SetBlipSprite(blip, 56)
        SetBlipColour(blip, 3)
        SetBlipScale(blip, 0.78)
        SetBlipAsShortRange(blip, false)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentString(('Unidade %s'):format(tostring(unit.plate or unitId)))
        EndTextCommandSetBlipName(blip)
        entry = { blip = blip }
        trackerBlips[unitId] = entry
      end
      SetBlipCoords(entry.blip, tonumber(coords.x), tonumber(coords.y), tonumber(coords.z))
      SetBlipRotation(entry.blip, math.floor(tonumber(unit.heading) or 0))
      entry.seenAt = now
    end
  end
  local staleAfter = math.max(5000, tonumber(response.staleAfterMs) or 10000)
  for unitId, entry in pairs(trackerBlips) do
    if not seen[unitId] and now - (entry.seenAt or 0) >= staleAfter then
      if DoesBlipExist(entry.blip) then RemoveBlip(entry.blip) end
      trackerBlips[unitId] = nil
    end
  end
end

local function scheduleTracker()
  if trackerV2Enabled() or not trackerViewing then return end
  SetTimeout(trackerRefreshMs, function()
    if not trackerViewing then return end
    request('trackerSnapshot', {}, function(response)
      if response.ok ~= true then
        trackerViewing = false
        removeTrackerBlips()
        notify(messages[response.code] or 'Rastreamento indisponível.', 'error')
        return
      end
      applyTrackerSnapshot(response)
      scheduleTracker()
    end)
  end)
end

local function openCctvMenu()
  request('cctvList', {}, function(response)
    if response.ok ~= true then notify(messages[response.code] or 'CCTV indisponível.', 'error'); return end
    local options = {}
    for _, camera in ipairs(response.cameras or {}) do
      options[#options + 1] = {
        title = tostring(camera.label or camera.id),
        description = tostring(camera.location or ''),
        icon = 'video',
        onSelect = function()
          request('cctvOpen', { cameraId = camera.id }, function(openResponse)
            if openResponse.ok == true then openCctv(openResponse.camera, openResponse.expiresAt)
            else notify(messages[openResponse.code] or 'Câmera indisponível.', 'error') end
          end)
        end
      }
    end
    if #options == 0 then
      options[1] = { title = 'Nenhuma câmera configurada', description = 'Informe posições reais em staging.', disabled = true }
    end
    MZPoliceClient.Panel.Open({ kind = 'list', title = 'CCTV autorizado', options = options })
  end)
end

local function openCameraStatus()
  request('cameraSnapshot', {}, function(response)
    if response.ok ~= true then notify(messages[response.code] or 'Consulta de câmeras negada.', 'error'); return end
    local options = {}
    for _, camera in ipairs(response.cameras or {}) do
      local active = {}
      if camera.bodycam then active[#active + 1] = 'bodycam' end
      if camera.dashcam then active[#active + 1] = ('dashcam %s'):format(tostring(camera.plate or '')) end
      options[#options + 1] = {
        title = tostring(camera.unitId or 'Unidade'),
        description = table.concat(active, ' • '),
        icon = 'camera',
        disabled = true
      }
    end
    if #options == 0 then options[1] = { title = 'Nenhuma câmera ativa', disabled = true } end
    options[#options + 1] = {
      title = 'Transmissão remota indisponível',
      description = 'O painel informa estado; não simula streaming ou gravação.',
      icon = 'circle-off',
      disabled = true
    }
    MZPoliceClient.Panel.Open({ kind = 'list', title = 'Câmeras ativas', options = options })
  end)
end

toggle = function(action, key, desired)
  local target = type(desired) == 'boolean' and desired or not state[key]
  request(action, { active = target }, function(response)
    if response.ok ~= true then notify(messages[response.code] or ('Operação negada: %s'):format(response.code), 'error'); return end
    applyState(response.state)
    if action == 'flirToggle' and state.flir then startFlir(response.camera) end
    notify(state[key] and 'Equipamento ativado.' or 'Equipamento desativado.', 'success')
    scheduleHeartbeat()
  end)
end

MZPoliceClient.SetAirCamera = function(active)
  if type(active) ~= 'boolean' or state.flir == active then return end
  toggle('flirToggle', 'flir', active)
end

MZPoliceClient.ToggleAirCamera = function()
  if type(state.flir) ~= 'boolean' then return end
  toggle('flirToggle', 'flir')
end

local function openMenu()
  request('status', {}, function(response)
    if response.ok ~= true then notify(messages[response.code] or 'Painel avançado indisponível.', 'error'); return end
    applyState(response.state)
    local configured = response.configured or {}
    MZPoliceClient.Panel.Open({
      kind = 'list',
      title = 'Sistemas policiais avançados',
      options = {
        { title = state.bodycam and 'Desativar bodycam' or 'Ativar bodycam', icon = 'camera',
          disabled = configured.cameras ~= true, onSelect = function() toggle('bodycamToggle', 'bodycam') end },
        { title = state.dashcam and 'Desativar dashcam' or 'Ativar dashcam', icon = 'car-front',
          disabled = configured.cameras ~= true, onSelect = function() toggle('dashcamToggle', 'dashcam') end },
        { title = 'Consultar CCTV', icon = 'video', disabled = configured.cameras ~= true,
          onSelect = openCctvMenu },
        { title = 'Consultar câmeras ativas', icon = 'list-video', disabled = configured.cameras ~= true,
          onSelect = openCameraStatus },
        { title = state.flir and 'Desativar FLIR' or 'Ativar FLIR', icon = 'scan',
          disabled = configured.air ~= true, onSelect = function()
            local heli = MZPoliceClient.Heli
            if type(heli) == 'table' and type(heli.ToggleCamera) == 'function' then
              heli.ToggleCamera()
            else
              toggle('flirToggle', 'flir')
            end
          end },
        { title = state.tracker and 'Desativar transmissor da unidade' or 'Ativar transmissor da unidade',
          icon = 'radio-tower', disabled = configured.tracker ~= true,
          onSelect = function() toggle('trackerBroadcast', 'tracker') end },
        { title = trackerViewing and 'Ocultar unidades rastreadas' or 'Exibir unidades rastreadas',
          icon = 'map-pin', disabled = configured.tracker ~= true, onSelect = function()
            if trackerV2Enabled() then
              trackerViewing = not trackerViewing
              if MZPoliceClient.Tracker then
                MZPoliceClient.Tracker.SetNativeVisible(trackerViewing)
              end
              return
            end
            trackerViewing = not trackerViewing
            if not trackerViewing then removeTrackerBlips(); return end
            request('trackerSnapshot', {}, function(snapshot)
              if snapshot.ok ~= true then trackerViewing = false; notify(messages[snapshot.code] or 'Rastreamento negado.', 'error'); return end
              applyTrackerSnapshot(snapshot)
              scheduleTracker()
            end)
          end }
      }
    })
  end)
end

RegisterNetEvent('mz_police:client:advanced:response', function(envelope)
  envelope = type(envelope) == 'table' and envelope or {}
  local requestId = tostring(envelope.requestId or '')
  local callback = pending[requestId]
  if not callback then return end
  pending[requestId] = nil
  callback(type(envelope.response) == 'table' and envelope.response or { ok = false, code = 'invalid_response' })
end)

RegisterCommand('mz_police_advanced', openMenu, false)

CreateThread(function()
  Wait(1000)
  while true do
    Wait((state.bodycam or state.dashcam or state.flir or state.tracker) and 0 or 500)
    local labels = {}
    if state.bodycam then labels[#labels + 1] = 'BODYCAM' end
    if state.dashcam then labels[#labels + 1] = ('DASHCAM %s'):format(tostring(state.dashcamVehicle and state.dashcamVehicle.plate or '')) end
    if state.flir then labels[#labels + 1] = 'FLIR' end
    if state.tracker then labels[#labels + 1] = 'TRACKER' end
    if #labels > 0 then
      SetTextFont(0)
      SetTextScale(0.28, 0.28)
      SetTextColour(116, 224, 255, 235)
      SetTextOutline()
      SetTextEntry('STRING')
      AddTextComponentString(table.concat(labels, '  •  '))
      DrawText(0.015, 0.82)
    end
  end
end)

AddEventHandler('onClientResourceStop', function(resourceName)
  if resourceName ~= GetCurrentResourceName() then return end
  stopFlir()
  stopCctv()
  removeTrackerBlips()
  if MZPoliceClient.Tracker then MZPoliceClient.Tracker.Stop() end
end)

MZPoliceClient.OpenAdvanced = openMenu
