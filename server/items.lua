-- Uso de algemas e chaves por qualquer jogador.
-- O item so abre o fluxo; a validacao real (item/UID, alvo, distancia,
-- bucket, estado e custodia) continua em MZPolice.Restraints.

MZPolice = MZPolice or {}

local function notifyResult(source, targetSource, action, code, ok, pending)
  TriggerClientEvent('mz_police:client:restraints:result', source, {
    action = action,
    targetSource = targetSource,
    response = {
      ok = ok == true,
      pending = pending == true,
      code = tostring(code or 'cuff_failed')
    }
  })
end

local function nearestPlayer(source)
  if type(GetPlayers) ~= 'function' or type(GetPlayerPed) ~= 'function'
    or type(GetEntityCoords) ~= 'function' then return nil, 'position_unavailable' end
  local ped = GetPlayerPed(source)
  if not ped or ped == 0 then return nil, 'position_unavailable' end
  local coords = GetEntityCoords(ped)
  if not coords then return nil, 'position_unavailable' end
  local bucket = type(GetPlayerRoutingBucket) == 'function' and tonumber(GetPlayerRoutingBucket(source)) or nil
  local maximum = tonumber(MZPoliceConfig.Restraints.maximumDistance)
    or tonumber(MZPoliceConfig.Custody.maximumDistance) or 2.5
  local selected, selectedDistance
  for _, rawSource in ipairs(GetPlayers() or {}) do
    local target = tonumber(rawSource)
    if target and target ~= source then
      local targetBucket = type(GetPlayerRoutingBucket) == 'function'
        and tonumber(GetPlayerRoutingBucket(target)) or bucket
      if not bucket or not targetBucket or bucket == targetBucket then
        local targetPed = GetPlayerPed(target)
        if targetPed and targetPed ~= 0 then
          local targetCoords = GetEntityCoords(targetPed)
          if targetCoords then
            local dx = coords.x - targetCoords.x
            local dy = coords.y - targetCoords.y
            local dz = coords.z - targetCoords.z
            local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
            if distance <= maximum and (not selectedDistance or distance < selectedDistance) then
              selected, selectedDistance = target, distance
            end
          end
        end
      end
    end
  end
  if not selected then return nil, 'target_too_far' end
  return selected
end

local function useRestraintItem(payload, action)
  payload = type(payload) == 'table' and payload or {}
  local source = tonumber(payload.source)
  if not source or source <= 0 then return { ok = false, error = 'invalid_source' } end

  local targetSource, selectionError = nearestPlayer(source)
  if not targetSource then
    notifyResult(source, nil, action, selectionError or 'target_too_far', false, false)
    return { ok = false, error = selectionError or 'target_too_far' }
  end

  local requestId = ('item_%s:%s:%s:%s'):format(
    action, tostring(source), tostring(targetSource), tostring(GetGameTimer()))
  local response = MZPolice.Restraints.request(source, {
    action = action,
    targetSource = targetSource,
    requestId = requestId,
    expectedRevision = MZPolice.Restraints.revision(targetSource) or 0,
    preferredUid = payload.instance_uid
  }, 'physical')

  if type(response) ~= 'table' or response.ok ~= true then
    local code = type(response) == 'table' and tostring(response.code or 'cuff_failed') or 'cuff_failed'
    notifyResult(source, targetSource, action, code, false, false)
    return { ok = false, error = code }
  end

  notifyResult(source, targetSource, action, response.code, true, response.pending)
  return {
    ok = true,
    consume = false,
    data = { targetSource = targetSource, itemUid = tostring(payload.instance_uid or '') }
  }
end

local function registerItemHandler()
  if GetResourceState('mz_inventory') ~= 'started' then return false end
  local ok, result = pcall(function()
    local cuffs = exports['mz_inventory']:RegisterItemUseHandler('handcuffs', function(payload)
      return useRestraintItem(payload, 'cuff')
    end)
    local key = exports['mz_inventory']:RegisterItemUseHandler('handcuff_key', function(payload)
      return useRestraintItem(payload, 'uncuff')
    end)
    return cuffs == true and key == true
  end)
  if not ok or result ~= true then
    print(('[mz_police][items] handcuffs use handler registration failed: %s'):format(
      tostring(ok and result or result)))
    return false
  end
  return true
end

CreateThread(function()
  Wait(1000)
  while not registerItemHandler() do Wait(1500) end
end)

AddEventHandler('onResourceStart', function(resourceName)
  if resourceName ~= 'mz_inventory' then return end
  CreateThread(function()
    Wait(500)
    registerItemHandler()
  end)
end)
