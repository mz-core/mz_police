MZPoliceClient = MZPoliceClient or {}

local contexts = {}
local requestedAt = {}
local requestSequence = 0
local activeSearch
-- Identidade, organizacao policial e duty confirmados pelo servidor. Cada acao
-- operacional continua revalidando sua propria capability no servidor.
local access = { checked = false, ok = false, code = 'pending' }

local messages = {
  capability_denied = 'Você não tem permissão para realizar essa operação.',
  duty_required = 'Você precisa estar em serviço.',
  target_too_far = 'Jogador fora do alcance.',
  routing_bucket_mismatch = 'Ação indisponível neste local.',
  target_not_in_custody = 'O cidadão precisa estar algemado.',
  target_offline = 'Jogador indisponível. Aguarde o personagem carregar.',
  target_state_unavailable = 'Não foi possível consultar o estado do alvo.',
  target_in_prison = 'O alvo já está sob custódia prisional.',
  prison_state_unavailable = 'Não foi possível consultar a situação prisional do alvo.',
  citizen_not_found = 'Cidadão não encontrado na base.',
  invalid_citizenid = 'Identidade do cidadão inválida.',
  custody_required = 'A custódia deste cidadão não pertence a você.',
  transfer_target_invalid = 'Informe um policial próximo e apto para assumir a custódia.',
  transfer_officer_unauthorized = 'O novo responsável não está em serviço ou não possui permissão.',
  processing_not_configured = 'O ponto de processamento policial não está configurado.',
  processing_point_required = 'Leve o custodiado ao balcão de processamento configurado.',
  processing_point_mismatch = 'Policial e custodiado precisam estar no mesmo ponto de processamento.',
  intake_not_configured = 'Local de recebimento não configurado.',
  intake_point_required = 'Leve o cidadão ao ponto de recebimento configurado.',
  prison_integration_disabled = 'A integração prisional está desativada.',
  prison_unavailable = 'O sistema prisional não está pronto. Tente novamente.',
  sentence_rule_mismatch = 'A acusação não corresponde ao catálogo prisional aprovado.',
  multi_charge_disabled = 'A sentença multi-acusação ainda não foi aprovada.',
  charge_already_sentenced = 'Uma das acusações já foi sentenciada.',
  aggregation_policy_not_supported = 'A política de agregação de penas não está aprovada.',
  invalid_primary_charge = 'A acusação principal da sentença é inválida.',
  legal_rules_disabled = 'O catálogo jurídico está desativado.',
  operation_busy = 'Ação indisponível no momento.',
  already_cuffed = 'O cidadão já está algemado.',
  not_cuffed = 'O cidadão não está algemado.',
  player_not_alive = 'O cidadão não está em condição válida.',
  target_busy = 'Outra pessoa está agindo sobre este alvo.',
  operation_pending = 'Já existe uma operação em andamento.',
  revision_conflict = 'O estado mudou. Tente novamente.',
  self_target_forbidden = 'Você não pode algemar a si mesmo.',
  organization_not_authorized = 'Sua organização não está autorizada para esta ação.',
  police_organization_not_found = 'Você não está em uma organização policial.',
  identity_unavailable = 'Identidade indisponível. Tente novamente.',
  organization_unavailable = 'Organização indisponível. Tente novamente.',
  authorization_unavailable = 'Autorização indisponível. Tente novamente.',
  internal_error = 'Falha interna ao processar a ação.',
  request_id_conflict = 'Solicitação duplicada. Tente novamente.',
  invalid_payload = 'Solicitação inválida.',
  invalid_source = 'Jogador inválido.',
  restraints_disabled = 'O sistema de algemas está desativado.',
  cuff_item_required = 'Você precisa de um par de algemas.',
  service_cuffs_disabled = 'Algemar por serviço exige item físico nesta configuração.',
  service_unlock_disabled = 'Desalgemar por serviço está desativado.',
  target_not_surrendered = 'O alvo precisa estar rendido ou incapacitado.',
  target_in_vehicle = 'O cidadão está em um veículo.',
  target_not_in_vehicle = 'O cidadão não está em um veículo.',
  vehicle_unavailable = 'Viatura indisponível.',
  actor_cuffed = 'Você está algemado e não pode executar esta ação.',
  already_escorted = 'O cidadão já está sendo escoltado.',
  not_escorted = 'O cidadão não está sendo escoltado.',
  cooldown = 'Aguarde antes de tentar novamente.',
  invalid_request = 'Solicitação inválida.',
  invalid_request_id = 'Identificador de solicitação inválido.',
  persistence_unavailable = 'Persistência de algemas indisponível.',
  restraint_apply_timeout = 'A aplicação da algema expirou. Tente novamente.',
  request_timeout = 'O servidor não respondeu dentro do limite.',
  invalid_response = 'Resposta inválida do servidor.',
  rate_limited = 'Aguarde antes de tentar novamente.'
}

local function notify(message, kind)
  if type(MZPoliceClient.Notify) == 'function' then
    MZPoliceClient.Notify(message, kind, 'Ações policiais')
  else
    print(('[mz_police] %s'):format(tostring(message)))
  end
end

local function responseMessage(response, fallback)
  local code = tostring(response and response.code or '')
  local helper = type(MZPoliceClient) == 'table' and MZPoliceClient.L or nil
  local debug = type(MZPoliceConfig) == 'table' and MZPoliceConfig.Debug or nil
  local suffix = code ~= '' and type(debug) == 'table' and debug.verboseErrors == true
    and (' [%s]'):format(code) or ''
  if type(helper) == 'function' and code ~= '' then
    local key = 'restraint.error.' .. code
    local translated = helper(key)
    if type(translated) == 'string' and translated ~= key then return translated .. suffix end
  end
  return (messages[code] or fallback or 'Ação indisponível no momento.') .. suffix
end

local function nextRequestId(prefix)
  requestSequence = requestSequence + 1
  return ('%s:%s:%s'):format(prefix, GetGameTimer(), requestSequence)
end

local function requestAccess()
  TriggerServerEvent('mz_police:server:requestAccess', nextRequestId('access'))
end

local function targetSource(context)
  local entity = context and tonumber(context.entity) or 0
  if entity > 0 and DoesEntityExist(entity) then
    if IsEntityAPed(entity) and IsPedAPlayer(entity) then
      local player = NetworkGetPlayerIndexFromPed(entity)
      if player and player ~= -1 then return GetPlayerServerId(player) end
    end
  end
  -- O target precisa ser o jogador explicitamente mirado; nunca use o vizinho.
  local target = context and context.target
  local targetServerId = type(target) == 'table' and tonumber(target.player_server_id) or nil
  if targetServerId and targetServerId > 0 then return targetServerId end
  return nil
end

local function requestContext(source)
  source = tonumber(source)
  if not source or source <= 0 then return end
  local now = GetGameTimer()
  if contexts[source] and now <= contexts[source].expiresAt then return end
  if now - (requestedAt[source] or 0) < 1000 then return end
  requestedAt[source] = now
  TriggerServerEvent('mz_police:server:interaction:context', { targetSource = source })
end

local function currentContext(context)
  local source = targetSource(context)
  if not source then return nil end
  requestContext(source)
  local cached = contexts[source]
  if not cached or GetGameTimer() > cached.expiresAt then return nil end
  return cached
end

local function can(action)
  return function(context)
    if not access.ok then return false end
    if not targetSource(context) then return false end
    local cached = currentContext(context)
    if cached then return cached.actions[action] == true or false end
    -- Antes da primeira resposta do servidor, mantem o submenu visivel para o
    -- policial autorizado com as acoes basicas; o servidor revalida o resto.
    return action == 'cuff' or action == 'identify' or action == 'open_mdt'
  end
end

local function performCustody(action, context)
  local source = targetSource(context)
  if not source then return false end
  local cached = contexts[source]
  -- O target pode confirmar a acao antes do primeiro contexto do servidor.
  -- Para cuff em alvo limpo, a revision inicial e 0; o servidor continua
  -- revalidando custodia, distancia, bucket e estado.
  TriggerServerEvent('mz_police:server:custody:request', {
    action = action,
    targetSource = source,
    expectedRevision = tonumber(cached and cached.revision) or 0,
    requestId = nextRequestId(action)
  })
  return true
end

local function itemRows(inventory)
  local rows = {}
  for _, section in ipairs({ 'main', 'equipment' }) do
    local snapshot = type(inventory) == 'table' and inventory[section] or nil
    for _, slot in pairs(type(snapshot) == 'table' and type(snapshot.slots) == 'table' and snapshot.slots or {}) do
      if type(slot) == 'table' then
        local uid = tostring(slot.stack_locator or slot.stackLocator or slot.instance_uid or slot.instanceUid or '')
        local amount = math.max(1, math.floor(tonumber(slot.amount) or 1))
        if uid ~= '' then
          rows[#rows + 1] = {
            uid = uid,
            amount = amount,
            label = tostring(slot.label or slot.item or slot.item_id or 'Item'),
            section = section
          }
        end
      end
    end
  end
  table.sort(rows, function(left, right) return left.label < right.label end)
  return rows
end

local function closeSearch()
  if not activeSearch then return end
  TriggerServerEvent('mz_police:server:search:close', { searchId = activeSearch.searchId })
  activeSearch = nil
end

local function openSearch(response)
  activeSearch = {
    searchId = response.searchId,
    targetSource = response.targetSource,
    canSeize = response.canSeize == true,
    inventory = response.inventory
  }
  local options = {}
  for _, item in ipairs(itemRows(activeSearch.inventory)) do
    local entry = item
    options[#options + 1] = {
      title = entry.label,
      description = ('%s • quantidade %s • UID %s'):format(entry.section, entry.amount, entry.uid),
      icon = entry.section == 'equipment' and 'shield' or 'package',
      readOnly = not activeSearch.canSeize,
      onSelect = activeSearch.canSeize and function()
        MZPoliceClient.Panel.Open({
          kind = 'form', title = 'Apreender item', subtitle = entry.label,
          confirmLabel = 'Apreender', fields = {
            { type = 'number', label = 'Quantidade', required = true, default = entry.amount, min = 1, max = entry.amount }
          }, onClose = closeSearch
        }, function(values)
          local amount = values and math.floor(tonumber(values[1]) or 0) or 0
          if amount < 1 or amount > entry.amount or not activeSearch then closeSearch(); return end
          TriggerServerEvent('mz_police:server:search:seize', {
            searchId = activeSearch.searchId,
            instanceUid = entry.uid,
            amount = amount,
            operationId = nextRequestId('seize'),
            containerId = tostring(MZPoliceConfig.Search.defaultEvidenceContainer or 'intake')
          })
        end)
      end or nil
    }
  end
  if #options == 0 then options[1] = { title = 'Nenhum item disponível', icon = 'inbox', readOnly = true } end
  options[#options + 1] = {
    title = 'Encerrar revista', icon = 'x', destructive = true,
    onSelect = closeSearch
  }
  MZPoliceClient.Panel.Open({
    kind = 'list',
    title = 'Revista policial',
    subtitle = activeSearch.canSeize and 'Apreensão autorizada e auditada' or 'Consulta sem permissão de apreensão',
    options = options,
    onClose = closeSearch
  })
end

local function perform(action, context)
  local source = targetSource(context)
  if not source then
    notify('Aproxime-se de um jogador para usar esta ação policial.', 'error')
    return false
  end
  if action == 'search' then
    if MZPoliceConfig.Search.thirdPartyInventoryEnabled == true then
      TriggerServerEvent('mz_police:server:thirdParty:openPolice', { targetSource = source })
    else
      TriggerServerEvent('mz_police:server:search:open', {
        targetSource = source, requestId = nextRequestId('search')
      })
    end
  elseif action == 'rob' then
    if MZPoliceConfig.Search.thirdPartyInventoryEnabled ~= true then return false end
    TriggerServerEvent('mz_police:server:thirdParty:openCivil', { targetSource = source })
  elseif action == 'transfer' then
    MZPoliceClient.Panel.Open({
      kind = 'form', title = 'Transferir custódia', confirmLabel = 'Transferir', fields = {
        { type = 'number', label = 'ID do policial próximo', required = true, min = 1 }
      }
    }, function(values)
      local newOfficerSource = values and math.floor(tonumber(values[1]) or 0) or 0
      if newOfficerSource <= 0 then return end
      local cached = contexts[source]
      TriggerServerEvent('mz_police:server:custody:request', {
        action = 'transfer', targetSource = source, newOfficerSource = newOfficerSource,
        expectedRevision = tonumber(cached and cached.revision) or 0,
        requestId = nextRequestId('transfer')
      })
    end)
  elseif action == 'identify' or action == 'openMdt' or action == 'processArrest' then
    TriggerServerEvent(('mz_police:server:interaction:%s'):format(action), { targetSource = source })
  else
    return performCustody(action, context)
  end
  return true
end

-- Interface interna para os adaptadores de target/radial. Nao cria owner novo:
-- custodia, acesso, MDT e capabilities continuam neste arquivo e no servidor.
MZPoliceClient.Interactions = {
  can = can,
  perform = perform,
  targetSource = targetSource,
  notify = notify,
  accessOk = function()
    return access.ok == true
  end
}

function MZPoliceClient.SetPendingIntake(value)
  if type(value) ~= 'table' then MZPoliceClient.PendingIntake = nil; return false end
  MZPoliceClient.PendingIntake = {
    targetSource = tonumber(value.targetSource),
    citizenid = tostring(value.citizenid or ''),
    caseId = tostring(value.caseId or ''),
    chargeId = tostring(value.chargeId or '')
  }
  return MZPoliceClient.PendingIntake.targetSource ~= nil
end

RegisterNetEvent('mz_police:client:prison:intake', function()
  local booking = MZPoliceClient.PendingIntake
  if not booking then
    notify('Prepare o encaminhamento na ficha do cidadão no MDT.', 'error')
    return
  end
  TriggerServerEvent('mz_police:server:prison:requestSentence', {
    targetSource = booking.targetSource,
    caseId = booking.caseId,
    chargeId = booking.chargeId,
    requestId = nextRequestId('sentence')
  })
end)

RegisterNetEvent('mz_police:client:interaction:result', function(result)
  result = type(result) == 'table' and result or {}
  local action, response = tostring(result.action or ''), type(result.response) == 'table' and result.response or {}
  if action == 'context' then
    local source = tonumber(response.targetSource)
    if response.ok == true and source then
      contexts[source] = {
        actions = type(response.actions) == 'table' and response.actions or {},
        state = type(response.state) == 'table' and response.state or {},
        revision = tonumber(response.revision) or 0,
        expiresAt = GetGameTimer() + 5000
      }
    end
    return
  end
  if response.ok ~= true then notify(responseMessage(response), 'error'); return end
  if action == 'identify' then
    local citizen = response.citizen or {}
    local name = table.concat({ tostring(citizen.firstname or ''), tostring(citizen.lastname or '') }, ' '):gsub('%s+', ' ')
    notify(('%s • %s'):format(name:gsub('^%s+', ''):gsub('%s+$', ''), tostring(citizen.citizenid or '')), 'success')
  elseif (action == 'openMdt' or action == 'processArrest')
    and type(MZPoliceClient.OpenMdtCitizen) == 'function' then
    MZPoliceClient.OpenMdtCitizen(response)
  end
end)

RegisterNetEvent('mz_police:client:custody:result', function(response)
  response = type(response) == 'table' and response or {}
  local source = tonumber(response.targetSource)
  if source then contexts[source] = nil; requestContext(source) end
  if response.ok == true and response.pending == true then
    notify('Aplicando restrição...', 'inform')
  elseif response.ok == true then
    notify('Estado de custódia atualizado.', 'success')
  else
    notify(responseMessage(response), 'error')
  end
end)

RegisterNetEvent('mz_police:client:search:result', function(response)
  response = type(response) == 'table' and response or {}
  if response.ok ~= true then notify(responseMessage(response), 'error'); return end
  if response.code == 'search_closed' then activeSearch = nil; return end
  openSearch(response)
end)

RegisterNetEvent('mz_police:client:prison:result', function(result)
  result = type(result) == 'table' and result or {}
  local response = type(result.response) == 'table' and result.response or {}
  if result.action ~= 'requestSentence' then return end
  if response.ok ~= true then notify(responseMessage(response), 'error'); return end
  MZPoliceClient.PendingIntake = nil
  local sentence = type(response.sentence) == 'table' and response.sentence or {}
  local chargeCount = type(sentence.charges) == 'table' and #sentence.charges or 1
  notify(('Entrada prisional confirmada. Sentença iniciada (%d acusação(ões)).'):format(chargeCount), 'success')
end)

local accessRetryCodes = {
  organization_not_ready = true,
  organization_unavailable = true,
  core_unavailable = true,
  character_not_active = true,
  identity_unavailable = true,
  identity_inconsistent = true,
  dependency_unavailable = true,
  contract_failed = true,
  contract_unavailable = true
}

RegisterNetEvent('mz_police:client:access', function(payload)
  payload = type(payload) == 'table' and payload or {}
  local previousOk, previousCode = access.ok, access.code
  access.ok = payload.ok == true
  access.code = tostring(payload.code or 'not_authorized')
  access.checked = access.ok or not accessRetryCodes[access.code]
  if access.ok ~= previousOk or access.code ~= previousCode then
    print(('[mz_police][target] access=%s code=%s'):format(tostring(access.ok), access.code))
    if not access.ok and access.code == 'duty_required' then
      notify('Ações policiais indisponíveis: entre em serviço no ponto de duty da organização (se o ponto não existir, configure-o no mz_org).', 'error')
    end
  end
end)

-- Diagnostico read-only para F8. Nao concede nada.
RegisterCommand('mz_police_target_status', function()
  if type(MZPoliceConfig.Debug) ~= 'table' or MZPoliceConfig.Debug.targetStatus ~= true then
    print('[mz_police][target] debug disabled by MZPoliceConfig.Debug.targetStatus')
    return
  end
  if access.ok ~= true then
    print(('[mz_police][target] debug denied access_code=%s'):format(tostring(access.code)))
    return
  end
  local targetStatus = MZPoliceClient.TargetIntegration
      and MZPoliceClient.TargetIntegration.GetStatus()
      or {}
  local radialStatus = MZPoliceClient.RadialIntegration
      and MZPoliceClient.RadialIntegration.GetStatus()
      or {}
  print(('[mz_police][target] mz_target=%s handle=%s radial=%s radial_handle=%s registry=%s registry_reason=%s access_checked=%s access_ok=%s access_code=%s duty=authorized'):format(
    tostring(GetResourceState('mz_target')),
    tostring(targetStatus.handle or 'none'),
    tostring(GetResourceState('mz_radialmenu')),
    tostring(radialStatus.handle or 'none'),
    tostring(targetStatus.state or 'missing'),
    tostring(targetStatus.reason or 'not_registered'),
    tostring(access.checked),
    tostring(access.ok),
    tostring(access.code)
  ))
end, false)

-- Duty/organizacao/personagem podem mudar em runtime; reconsulta a autorizacao.
-- O servidor limita consultas de policy por uma janela curta e descarta a copia
-- excedente sem resposta. Como cada toggle de duty dispara mais de uma consulta
-- no mesmo tick, a resposta pode nunca chegar se apenas reenviarmos uma vez por
-- evento. Zerar access.checked reativa o laco de retry existente (o mesmo usado
-- no boot) ate o servidor devolver uma resposta nova para o estado atual.
local function refreshAccess()
  access.checked = false
  requestAccess()
end

RegisterNetEvent('mz_org:client:dutyResult', refreshAccess)
RegisterNetEvent('mz_org:client:organizationsChanged', refreshAccess)
RegisterNetEvent('mz_core:client:playerLoaded', refreshAccess)

-- Enquanto o servidor nao responder, tenta de novo a cada 3s (org/core podem
-- estar inicializando). Apos a primeira resposta o laco para; uma mudanca de
-- duty/organizacao/personagem zera access.checked e o laco volta a reconsultar
-- ate receber resposta nova, sem polling permanente e respeitando o rate limit.
CreateThread(function()
  Wait(1000)
  while true do
    if not access.checked then requestAccess() end
    Wait(3000)
  end
end)

AddEventHandler('onClientResourceStart', function(resourceName)
  if resourceName == 'mz_org' or resourceName == GetCurrentResourceName() then
    CreateThread(function()
      Wait(500)
      requestAccess()
    end)
  end
end)

AddEventHandler('onClientResourceStop', function(resourceName)
  if resourceName ~= GetCurrentResourceName() then return end
  closeSearch()
end)
