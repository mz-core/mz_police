-- Camera aerea do mz_police.
-- A autorizacao do FLIR continua no servidor (server/advanced.lua). Este arquivo
-- apenas apresenta a camera, faz leitura local do veiculo mirado e despacha os
-- controles de refletor/rapel para os contratos canonicos ja existentes.

MZPoliceClient = MZPoliceClient or {}

local FOV_MAX = 80.0
local FOV_MIN = 10.0
local ZOOM_SPEED = 2.0
local SPEED_LR = 3.0
local SPEED_UD = 3.0

-- Controles usados pelo helicam do qb-policejob.
local CONTROL_TOGGLE = 51      -- E / INPUT_CONTEXT
local CONTROL_VISION = 25      -- botao direito / INPUT_AIM
local CONTROL_RAPPEL = 154     -- X / INPUT_DUCK
local CONTROL_SPOTLIGHT = 74   -- H / INPUT_VEH_HEADLIGHT
local CONTROL_LOCK = 22        -- espaco / INPUT_SPRINT
local CONTROL_ZOOM_IN = 241    -- scroll up
local CONTROL_ZOOM_OUT = 242   -- scroll down

local camera, heliVehicle, heliOffset, scaleform
local fov = (FOV_MAX + FOV_MIN) * 0.5
local fovMin, fovMax = FOV_MIN, FOV_MAX
local vision = 0 -- 0 normal, 1 noturna, 2 termica
local spotlight = false
local scanning, scanned, scanValue = false, false, 0
local detectedVehicle, lockedVehicle
local helpUntil = 0

local notices = {
  air_support_disabled = 'Suporte aéreo desativado.',
  capability_denied = 'Você não possui permissão para usar o refletor.',
  duty_required = 'Você precisa estar em serviço.',
  vehicle_required = 'Entre em uma aeronave autorizada.',
  vehicle_not_authorized = 'Esta aeronave não está autorizada.',
  seat_not_authorized = 'Somente o piloto ou o copiloto pode controlar o refletor.',
  rate_limited = 'Aguarde antes de tentar novamente.'
}

local function notify(message, kind)
  if type(MZPoliceClient.Notify) == 'function' then
    MZPoliceClient.Notify(message, kind, 'Câmera aérea')
  else
    print(('[mz_police][heli] %s'):format(tostring(message)))
  end
end

local function airConfig()
  local advanced = type(MZPoliceConfig) == 'table' and MZPoliceConfig.Advanced or nil
  return type(advanced) == 'table' and type(advanced.Air) == 'table' and advanced.Air or {}
end

local function accessOk()
  local interactions = MZPoliceClient.Interactions
  return type(interactions) == 'table' and interactions.accessOk() == true
end

local function configuredHeli(vehicle)
  local models = airConfig().helicopterModels
  if vehicle == 0 or vehicle == nil or type(models) ~= 'table' then return false end
  for model, enabled in pairs(models) do
    if enabled == true and IsVehicleModel(vehicle, GetHashKey(model)) then return true end
  end
  return false
end

local function currentHeli()
  local ped = PlayerPedId()
  local vehicle = GetVehiclePedIsIn(ped, false)
  if vehicle ~= 0 and configuredHeli(vehicle) then return vehicle, ped end
  return nil
end

local function isHighEnough(vehicle)
  return vehicle ~= nil and GetEntityHeightAboveGround(vehicle) > 1.5
end

local function playSelect()
  PlaySoundFrontend(-1, 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', false)
end

local function setHudSuppressed(suppressed)
  if GetResourceState('mz_hud') ~= 'started' then return end
  pcall(function() exports['mz_hud']:SetSuppressed('mz_police_heli', suppressed == true) end)
end

local function applyVision()
  SetNightvision(vision == 1)
  SetSeethrough(vision == 2)
end

local function cycleVision()
  if not camera then return false end
  vision = (vision + 1) % 3
  applyVision()
  playSelect()
  return true
end

local function hideHud()
  HideHelpTextThisFrame()
  HideHudAndRadarThisFrame()
  for _, component in ipairs({ 19, 1, 2, 3, 4, 13, 11, 12, 15, 18 }) do
    HideHudComponentThisFrame(component)
  end
end

local function rotAnglesToVec(rot)
  local z, x = math.rad(rot.z), math.rad(rot.x)
  local num = math.abs(math.cos(x))
  return vector3(-math.sin(z) * num, math.cos(z) * num, math.sin(x))
end

local function vehicleInView(cam)
  local coords = GetCamCoord(cam)
  local forward = rotAnglesToVec(GetCamRot(cam, 2))
  local handle = CastRayPointToPoint(coords, coords + (forward * 400.0), 10, heliVehicle or 0, 0)
  local _, _, _, _, entity = GetRaycastResult(handle)
  if entity and entity > 0 and IsEntityAVehicle(entity) then return entity end
  return nil
end

local function drawText(text, x, y, scale, centre, colour)
  colour = type(colour) == 'table' and colour or { 255, 255, 255, 235 }
  SetTextFont(4)
  SetTextScale(scale or 0.32, scale or 0.32)
  SetTextColour(colour[1] or 255, colour[2] or 255, colour[3] or 255, colour[4] or 235)
  SetTextOutline()
  SetTextCentre(centre == true)
  SetTextEntry('STRING')
  AddTextComponentString(tostring(text or ''))
  DrawText(x, y)
end

local function drawScanBar()
  local baseX, baseBottom = 0.37, 0.61
  local outerWidth, outerHeight = 0.007, 0.20
  local innerWidth, innerHeight = 0.004, 0.194
  DrawRect(baseX, baseBottom - (outerHeight * 0.5), outerWidth, outerHeight, 204, 204, 204, 170)
  DrawRect(baseX, baseBottom - (outerHeight * 0.5), innerWidth, innerHeight, 0, 0, 0, 150)
  local fill = math.max(0.0, math.min(100.0, tonumber(scanValue) or 0.0)) / 100.0
  if fill > 0.0 then
    local height = innerHeight * fill
    DrawRect(baseX, baseBottom - (height * 0.5), innerWidth, height, 220, 220, 220, 230)
  end
end

local function drawCrosshair()
  local centreX, centreY = 0.5, 0.5
  local halfW, halfH = 0.018, 0.032
  local thickness = 0.0012
  DrawRect(centreX, centreY - halfH, halfW * 2.0, thickness, 171, 12, 12, 190)
  DrawRect(centreX, centreY + halfH, halfW * 2.0, thickness, 171, 12, 12, 190)
  DrawRect(centreX - halfW, centreY, thickness, halfH * 2.0, 171, 12, 12, 190)
  DrawRect(centreX + halfW, centreY, thickness, halfH * 2.0, 171, 12, 12, 190)
end

local function targetInfo(target)
  local pos = GetEntityCoords(target)
  local model = GetDisplayNameFromVehicleModel(GetEntityModel(target))
  local label = GetLabelText(model)
  if type(label) ~= 'string' or label == '' or label == 'NULL' then label = model end
  local plate = tostring(GetVehicleNumberPlateText(target) or ''):gsub('%s+$', '')
  local speed = math.ceil(GetEntitySpeed(target) * 3.6)
  local street1, street2 = GetStreetNameAtCoord(pos.x, pos.y, pos.z)
  local street = GetStreetNameFromHashKey(street1)
  if street2 and street2 ~= 0 then
    street = street .. ' | ' .. GetStreetNameFromHashKey(street2)
  end
  return tostring(label or ''), plate, speed, tostring(street or '')
end

local function drawTargetInfo(target)
  if not target or target == 0 or not DoesEntityExist(target) then return end
  local model, plate, speed, street = targetInfo(target)
  drawCrosshair()
  drawText(('MODELO: %s'):format(model), 0.5, 0.34, 0.36, true)
  drawText(('%d KM/H'):format(speed), 0.35, 0.35, 0.34, false)
  drawText(street, 0.70, 0.507, 0.32, false)
  drawText(('PLACA: %s'):format(plate), 0.5, 0.70, 0.36, true)
end

local function drawHelp()
  if GetGameTimer() > helpUntil then return end
  drawText('E sair   |   RMB visão   |   SCROLL zoom   |   ESPAÇO destravar   |   H refletor   |   X rapel',
    0.5, 0.965, 0.26, true, { 220, 230, 240, 225 })
end

local function drawCameraHud(cam, zoomValue)
  local vehicle = heliVehicle
  if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return end
  if not scaleform then scaleform = RequestScaleformMovie('HELI_CAM') end
  if scaleform and HasScaleformMovieLoaded(scaleform) then
    PushScaleformMovieFunction(scaleform, 'SET_ALT_FOV_HEADING')
    PushScaleformMovieFunctionParameterFloat(GetEntityCoords(vehicle).z)
    PushScaleformMovieFunctionParameterFloat(zoomValue or 0.0)
    PushScaleformMovieFunctionParameterFloat(GetCamRot(cam, 2).z)
    PopScaleformMovieFunctionVoid()
    DrawScaleformMovieFullscreen(scaleform, 255, 255, 255, 255)
  end
  drawScanBar()
  if lockedVehicle and DoesEntityExist(lockedVehicle) then drawTargetInfo(lockedVehicle) end
  drawHelp()
end

local function destroyCamera()
  if camera then
    RenderScriptCams(false, false, 0, true, true)
    DestroyCam(camera, false)
    camera = nil
  end
end

local function stopCamera()
  destroyCamera()
  ClearTimecycleModifier()
  SetNightvision(false)
  SetSeethrough(false)
  if scaleform then
    SetScaleformMovieAsNoLongerNeeded(scaleform)
    scaleform = nil
  end
  heliVehicle, heliOffset = nil, nil
  vision, scanning, scanned, scanValue = 0, false, false, 0
  detectedVehicle, lockedVehicle = nil, nil
  fov = (fovMax + fovMin) * 0.5
  setHudSuppressed(false)
end

local function checkInputRotation(cam, zoomValue)
  local rightAxisX = GetDisabledControlNormal(0, 220)
  local rightAxisY = GetDisabledControlNormal(0, 221)
  local rotation = GetCamRot(cam, 2)
  if rightAxisX ~= 0.0 or rightAxisY ~= 0.0 then
    local newZ = rotation.z + rightAxisX * -1.0 * SPEED_UD * (zoomValue + 0.1)
    local newX = math.max(math.min(20.0, rotation.x + rightAxisY * -1.0 * SPEED_LR * (zoomValue + 0.1)), -89.5)
    SetCamRot(cam, newX, 0.0, newZ, 2)
  end
end

local function handleZoom(cam)
  if IsDisabledControlJustPressed(0, CONTROL_ZOOM_IN) then
    fov = math.max(fov - ZOOM_SPEED, fovMin)
  end
  if IsDisabledControlJustPressed(0, CONTROL_ZOOM_OUT) then
    fov = math.min(fov + ZOOM_SPEED, fovMax)
  end
  local current = GetCamFov(cam)
  if math.abs(fov - current) < 0.1 then fov = current end
  SetCamFov(cam, current + (fov - current) * 0.05)
end

local function createAttachedCamera()
  local offset = heliOffset or { x = 0.0, y = 0.0, z = -1.5 }
  camera = CreateCam('DEFAULT_SCRIPTED_FLY_CAMERA', true)
  AttachCamToEntity(camera, heliVehicle, tonumber(offset.x) or 0.0, tonumber(offset.y) or 0.0,
    tonumber(offset.z) or -1.5, true)
  SetCamRot(camera, 0.0, 0.0, GetEntityHeading(heliVehicle), 2)
  SetCamFov(camera, fov)
  SetCamActive(camera, true)
  RenderScriptCams(true, false, 0, true, true)
end

local function unlockCamera()
  if not lockedVehicle or not camera or not heliVehicle then return end
  local rotation = GetCamRot(camera, 2)
  local currentFov = GetCamFov(camera)
  local old = camera
  camera = nil
  lockedVehicle, detectedVehicle = nil, nil
  scanning, scanned, scanValue = false, false, 0
  createAttachedCamera()
  if not camera then return end
  SetCamRot(camera, rotation.x, rotation.y, rotation.z, 2)
  SetCamFov(camera, currentFov)
  RenderScriptCams(true, false, 0, true, true)
  DestroyCam(old, false)
  fov = currentFov
  playSelect()
end

local function startScanThread()
  CreateThread(function()
    while camera do
      Wait(10)
      if camera then
        if lockedVehicle then
          if DoesEntityExist(lockedVehicle) then
            scanValue = 100
          else
            lockedVehicle, detectedVehicle = nil, nil
            scanning, scanned, scanValue = false, false, 0
          end
        elseif scanning and detectedVehicle and DoesEntityExist(detectedVehicle) then
          scanValue = math.min(100, scanValue + 1)
          if scanValue >= 100 then
            lockedVehicle = detectedVehicle
            scanning, scanned = false, true
            playSelect()
          end
        else
          scanValue = math.max(0, scanValue - 5)
          if scanValue <= 0 then scanned = false end
        end
      end
    end
  end)
end

local function startCameraLoop()
  CreateThread(function()
    while camera do
      local cam = camera
      local vehicle = heliVehicle
      if not cam or not vehicle or not DoesEntityExist(vehicle)
        or GetVehiclePedIsIn(PlayerPedId(), false) ~= vehicle or not isHighEnough(vehicle) then
        if type(MZPoliceClient.SetAirCamera) == 'function' then
          MZPoliceClient.SetAirCamera(false)
        end
        break
      end

      Wait(0)
      -- stopCamera pode rodar em outro thread durante o Wait; nunca use a
      -- camera/aeronave antiga depois que o estado canonico foi limpo.
      if camera ~= cam or not heliVehicle or not DoesEntityExist(heliVehicle) then break end
      DisableControlAction(0, 1, true)
      DisableControlAction(0, 2, true)
      DisableControlAction(0, CONTROL_VISION, true)
      DisableControlAction(0, CONTROL_LOCK, true)
      DisableControlAction(0, CONTROL_ZOOM_IN, true)
      DisableControlAction(0, CONTROL_ZOOM_OUT, true)

      if IsDisabledControlJustPressed(0, CONTROL_VISION) then cycleVision() end
      if IsDisabledControlJustPressed(0, CONTROL_LOCK) and lockedVehicle then
        unlockCamera()
        cam = camera
      end
      if not cam then break end

      local zoomValue = 0.0
      if lockedVehicle then
        if DoesEntityExist(lockedVehicle) then
          PointCamAtEntity(cam, lockedVehicle, 0.0, 0.0, 0.0, true)
        else
          lockedVehicle, detectedVehicle = nil, nil
          scanning, scanned, scanValue = false, false, 0
        end
      else
        zoomValue = (1.0 / math.max(0.01, fovMax - fovMin)) * (fov - fovMin)
        checkInputRotation(cam, zoomValue)
        detectedVehicle = vehicleInView(cam)
        scanning = detectedVehicle ~= nil
      end

      handleZoom(cam)
      hideHud()
      drawCameraHud(cam, zoomValue)
    end
    stopCamera()
  end)
end

local function startCamera(config)
  config = type(config) == 'table' and config or {}
  local vehicle = NetworkGetEntityFromNetworkId(tonumber(config.vehicleNetworkId) or 0)
  if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
    return false, 'A aeronave autorizada não está disponível.'
  end
  if GetVehiclePedIsIn(PlayerPedId(), false) ~= vehicle then
    return false, 'Entre na aeronave autorizada para usar a câmera aérea.'
  end
  if not isHighEnough(vehicle) then
    return false, 'A aeronave precisa estar no ar para usar a câmera aérea.'
  end

  stopCamera()
  heliVehicle = vehicle
  heliOffset = type(config.offset) == 'table' and config.offset or { x = 0.0, y = 0.0, z = -1.5 }
  fovMin = math.max(5.0, tonumber(config.minimumFov) or FOV_MIN)
  fovMax = math.min(100.0, tonumber(config.maximumFov) or FOV_MAX)
  if fovMax <= fovMin then
    fovMin, fovMax = FOV_MIN, FOV_MAX
  end
  fov = (fovMax + fovMin) * 0.5
  vision, scanning, scanned, scanValue = 0, false, false, 0
  detectedVehicle, lockedVehicle = nil, nil
  helpUntil = GetGameTimer() + 9000

  createAttachedCamera()
  if not camera then
    heliVehicle, heliOffset = nil, nil
    return false, 'Não foi possível criar a câmera aérea.'
  end
  SetTimecycleModifier('heliGunCam')
  SetTimecycleModifierStrength(0.3)
  applyVision()
  setHudSuppressed(true)
  startScanThread()
  startCameraLoop()
  return true
end

local function toggleCamera()
  if camera then
    playSelect()
    if type(MZPoliceClient.ToggleAirCamera) == 'function' then MZPoliceClient.ToggleAirCamera() end
    return true
  end
  local vehicle = currentHeli()
  if not vehicle then
    notify('Entre em um helicóptero autorizado.', 'error')
    return false
  end
  if not accessOk() then
    notify('Você precisa estar em serviço.', 'error')
    return false
  end
  if not isHighEnough(vehicle) then
    notify('A aeronave precisa estar no ar.', 'error')
    return false
  end
  if type(MZPoliceClient.ToggleAirCamera) ~= 'function' then return false end
  playSelect()
  MZPoliceClient.ToggleAirCamera()
  return true
end

local function toggleSpotlight()
  local vehicle, ped = currentHeli()
  if not vehicle then return false end
  if GetPedInVehicleSeat(vehicle, -1) ~= ped and GetPedInVehicleSeat(vehicle, 0) ~= ped then
    notify('Somente o piloto ou o copiloto pode controlar o refletor.', 'error')
    return false
  end
  playSelect()
  TriggerServerEvent('mz_police:server:heli:spotlight', not spotlight)
  return true
end

local function rappel()
  local vehicle, ped = currentHeli()
  if not vehicle then
    notify('Entre em um helicóptero autorizado.', 'error')
    return false
  end
  if not isHighEnough(vehicle) then
    notify('A aeronave precisa estar no ar para o rapel.', 'error')
    return false
  end
  local seat = GetPedInVehicleSeat(vehicle, 1) == ped and 1
    or (GetPedInVehicleSeat(vehicle, 2) == ped and 2 or nil)
  if not seat then
    notify('O rapel está disponível apenas nos assentos laterais.', 'error')
    return false
  end
  playSelect()
  TaskRappelFromHeli(ped, 1)
  return true
end

RegisterNetEvent('mz_police:client:heli:spotlight', function(networkId, active)
  local id = tonumber(networkId) or 0
  local entity = NetworkGetEntityFromNetworkId(id)
  if not entity or entity == 0 or not DoesEntityExist(entity) then return end
  SetVehicleSearchlight(entity, active == true, false)
  local current = currentHeli()
  if current and NetworkGetNetworkIdFromEntity(current) == id then
    spotlight = active == true
  end
end)

RegisterNetEvent('mz_police:client:heli:notice', function(code)
  notify(notices[tostring(code or '')] or 'Refletor indisponível.', 'error')
end)

local trackedHeli
CreateThread(function()
  while true do
    Wait(0)
    local vehicle, ped = currentHeli()
    if vehicle ~= trackedHeli then
      trackedHeli = vehicle
      spotlight = false
    end
    if vehicle and accessOk() then
      if isHighEnough(vehicle) and IsControlJustPressed(0, CONTROL_TOGGLE) then
        toggleCamera()
      end

      DisableControlAction(0, CONTROL_SPOTLIGHT, true)
      if IsDisabledControlJustPressed(0, CONTROL_SPOTLIGHT) then
        if GetPedInVehicleSeat(vehicle, -1) == ped or GetPedInVehicleSeat(vehicle, 0) == ped then
          toggleSpotlight()
        end
      end

      DisableControlAction(0, CONTROL_RAPPEL, true)
      if IsDisabledControlJustPressed(0, CONTROL_RAPPEL) then rappel() end
      Wait(0)
    else
      Wait(500)
    end
  end
end)

RegisterCommand('mz_police_heli', function()
  if not accessOk() then return end
  toggleCamera()
end, false)

AddEventHandler('onClientResourceStop', function(resourceName)
  if resourceName ~= GetCurrentResourceName() then return end
  stopCamera()
end)

MZPoliceClient.Heli = {
  Start = startCamera,
  Stop = stopCamera,
  ToggleCamera = toggleCamera,
  CycleVision = cycleVision,
  ToggleSpotlight = toggleSpotlight,
  Rappel = rappel,
  IsActive = function() return camera ~= nil end,
  IsInHeli = function() return currentHeli() ~= nil end
}
