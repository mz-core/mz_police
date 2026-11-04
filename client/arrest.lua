MZPoliceClient = MZPoliceClient or {}

-- Formulario compacto da prisao rapida.
--
-- A NUI apenas escolhe ruleCodes e escreve uma observacao. Pena, multa, nome
-- da regra e versao legal vem do servidor em preview/quote/commit.

local pending = {}
local sequence = 0
local opening = false
local openingSince = 0
local timeoutMs = 12000

local messages = {
  arrest_disabled = 'A prisão rápida está desativada.',
  records_unavailable = 'O backend de registros não está pronto.',
  rate_limited = 'Aguarde antes de tentar novamente.',
  capability_denied = 'Você não tem permissão para prender.',
  duty_required = 'Você precisa estar em serviço.',
  custody_required = 'O cidadão precisa estar algemado e sob sua custódia.',
  invalid_custody_identity = 'A identidade do custodiado não pôde ser confirmada.',
  revision_conflict = 'O estado da custódia mudou. Tente novamente.',
  player_not_alive = 'O cidadão não está em condição de ser preso.',
  target_too_far = 'Jogador fora do alcance.',
  routing_bucket_mismatch = 'Ação indisponível neste local.',
  position_unavailable = 'Não foi possível confirmar a posição.',
  legal_rules_disabled = 'O catálogo jurídico está desativado.',
  jurisdiction_disabled = 'A jurisdição policial ainda não foi aprovada.',
  legal_rule_not_configured = 'A acusação selecionada não está configurada.',
  no_custodial_charge = 'Nenhuma acusação com pena foi selecionada.',
  multi_charge_disabled = 'A sentença multi-acusação ainda não foi aprovada.',
  charge_already_sentenced = 'Uma das acusações já foi sentenciada.',
  aggregation_policy_not_supported = 'A política de agregação de penas não está aprovada.',
  invalid_primary_charge = 'A acusação principal da sentença é inválida.',
  invalid_charge_count = 'Quantidade de acusações inválida.',
  invalid_charges = 'Selecione acusações válidas e distintas.',
  citation_capability_required = 'Você não tem permissão para emitir a multa desta acusação.',
  citation_not_found = 'A multa não foi encontrada para este cidadão.',
  citation_not_payable = 'Esta multa não está pendente de pagamento.',
  not_enough_money = 'Saldo insuficiente para pagar a multa.',
  active_sentence_exists = 'O cidadão já possui uma sentença ativa.',
  sentence_read_failed = 'Não foi possível consultar a situação prisional.',
  prison_unavailable = 'O sistema prisional não está pronto.',
  notes_too_long = 'A observação é longa demais.',
  persistence_failed = 'O registro não pôde ser salvo. Nada foi confirmado.',
  request_id_conflict = 'Esta solicitação já foi usada com outro conteúdo.',
  operation_busy = 'Já existe uma operação em andamento para este cidadão.',
  request_timeout = 'O servidor não respondeu dentro do limite.',
  invalid_response = 'Resposta inválida do servidor.',
  preview_only = 'Preview visual isolado.'
}

local function notify(message, kind)
  if type(MZPoliceClient.Notify) == 'function' then
    MZPoliceClient.Notify(message, kind, 'Prisão rápida')
  else
    print(('[mz_police] %s'):format(tostring(message)))
  end
end

local function messageFor(response, fallback)
  local code = tostring(response and response.code or '')
  local message = messages[code] or fallback or 'Ação indisponível no momento.'
  local debug = type(MZPoliceConfig) == 'table' and MZPoliceConfig.Debug or nil
  if code ~= '' and type(debug) == 'table' and debug.verboseErrors == true then
    message = ('%s [%s]'):format(message, code)
  end
  return message
end

local function nextId(prefix)
  sequence = sequence + 1
  return ('%s:%s:%s'):format(prefix, GetGameTimer(), sequence)
end

local function request(action, payload)
  local id = nextId('arrest_' .. tostring(action))
  payload = type(payload) == 'table' and payload or {}
  payload.requestId = id
  pending[id] = { done = false }
  TriggerServerEvent(('mz_police:server:arrest:%s'):format(tostring(action)), payload)

  local deadline = GetGameTimer() + timeoutMs
  while pending[id] and pending[id].done ~= true and GetGameTimer() < deadline do Wait(25) end
  local entry = pending[id]
  pending[id] = nil
  if not entry or entry.done ~= true then return { ok = false, code = 'request_timeout' } end
  return type(entry.response) == 'table' and entry.response or { ok = false, code = 'invalid_response' }
end

RegisterNetEvent('mz_police:client:arrest:result', function(result)
  result = type(result) == 'table' and result or {}
  local id = tostring(result.requestId or '')
  if id == '' then return end
  local waiter = pending[id]
  if not waiter then return end
  waiter.response = result.response
  waiter.done = true
end)

local function money(amount)
  return ('R$ %d'):format(math.floor(tonumber(amount) or 0))
end

local function chargeOptions(charges)
  local options = {}
  for _, charge in ipairs(charges or {}) do
    options[#options + 1] = {
      value = tostring(charge.code),
      label = ('%s · %ss · %s'):format(
        tostring(charge.name or charge.code), tostring(charge.sentenceSeconds or 0), money(charge.fineAmount)
      )
    }
  end
  return options
end

local function buildRows(preview)
  local charges = preview.catalog and preview.catalog.charges or {}
  local options = chargeOptions(charges)
  if #options == 0 then return nil, 'no_custodial_charge' end
  local maximum = math.max(1, math.min(3, math.floor(tonumber(preview.limits and preview.limits.maxCharges) or 1)))
  local rows = {}
  for index = 1, maximum do
    local rowOptions = options
    if index > 1 then
      rowOptions = { { value = '', label = 'Nenhuma' } }
      for _, option in ipairs(options) do rowOptions[#rowOptions + 1] = option end
    end
    rows[#rows + 1] = {
      type = 'select',
      label = index == 1 and 'Acusação' or ('Acusação adicional %d'):format(index),
      options = rowOptions,
      required = index == 1,
      default = index == 1 and options[1].value or ''
    }
  end
  rows[#rows + 1] = {
    type = 'textarea',
    label = 'Observação',
    placeholder = 'Opcional, até 4000 caracteres',
    default = ''
  }
  return rows, nil
end

local function selectedCodes(values, maximum)
  local codes, seen = {}, {}
  for index = 1, maximum do
    local value = tostring(values[index] or '')
    if value ~= '' and not seen[value] then
      seen[value] = true
      codes[#codes + 1] = value
    end
  end
  return codes
end

RegisterNetEvent('mz_police:client:citations:result', function(response)
  response = type(response) == 'table' and response or {}
  if response.ok == true then
    notify('Multa paga com sucesso.', 'success')
  else
    notify(messageFor(response), 'error')
  end
end)

RegisterNetEvent('mz_police:client:citations:paymentRequest', function(payload)
  payload = type(payload) == 'table' and payload or {}
  local citationId = tostring(payload.citationId or '')
  local amount = math.floor(tonumber(payload.amount) or 0)
  if #citationId < 8 or #citationId > 160 or not citationId:match('^[%w:_-]+$') or amount <= 0 then return end
  MZPoliceClient.Panel.Open({
    kind = 'confirm', title = 'Pagamento de multa',
    subtitle = ('%s · %s. O débito só ocorre após sua confirmação.'):format(
      tostring(payload.ruleName or 'Infração'), money(amount)),
    confirmLabel = 'Pagar', cancelLabel = 'Agora não'
  }, function(confirmed)
    if not confirmed then return end
    TriggerServerEvent('mz_police:server:citations:pay', {
      citationId = citationId, requestId = nextId('citation_pay')
    })
  end)
end)

function MZPoliceClient.OpenQuickArrest(targetSource)
  targetSource = tonumber(targetSource)
  if not targetSource or targetSource <= 0 then
    notify('Aproxime-se de um jogador para prendê-lo.', 'error')
    return false
  end
  if opening and GetGameTimer() - openingSince < 30000 then return false end
  opening = true
  openingSince = GetGameTimer()
  CreateThread(function()
    local preview = request('preview', { targetSource = targetSource, mode = 'quick' })
    if preview.ok ~= true then
      notify(messageFor(preview), 'error')
      opening = false
      return
    end
    if preview.sentence and preview.sentence.active == true then
      notify(messages.active_sentence_exists, 'error')
      opening = false
      return
    end

    local rows, rowsError = buildRows(preview)
    if not rows then
      notify(messageFor({ code = rowsError }), 'error')
      opening = false
      return
    end

    MZPoliceClient.Panel.Open({
      kind = 'form',
      title = ('Prisão rápida — %s'):format(tostring(preview.target and preview.target.name or 'Cidadão')),
      fields = rows, confirmLabel = 'Calcular', onClose = function() opening = false end
    }, function(values)
      CreateThread(function()
        local maximum = math.max(1, math.min(3, math.floor(tonumber(preview.limits and preview.limits.maxCharges) or 1)))
        local codes = selectedCodes(values, maximum)
        local notes = tostring(values[maximum + 1] or '')
        if #codes == 0 then notify(messages.invalid_charges, 'error'); opening = false; return end

        local quote = request('quote', { targetSource = targetSource, ruleCodes = codes, mode = 'quick' })
        if quote.ok ~= true then notify(messageFor(quote), 'error'); opening = false; return end
        local totals = quote.totals or {}
        MZPoliceClient.Panel.Open({
          kind = 'confirm', title = 'Confirmar prisão',
          subtitle = ('Pena: %ss · Multa: %s · %d acusação(ões)'):format(
            tostring(totals.sentenceSeconds or 0), money(totals.fineAmount), tonumber(totals.chargeCount) or #codes),
          confirmLabel = 'Prender', cancelLabel = 'Cancelar', onClose = function() opening = false end
        }, function(confirmed)
          if not confirmed then opening = false; return end
          CreateThread(function()
            local commit = request('commit', {
              targetSource = targetSource, ruleCodes = codes, notes = notes, mode = 'quick',
              expectedCustodyRevision = tonumber(preview.custody and preview.custody.revision) or 0
            })
            if commit.ok ~= true then notify(messageFor(commit), 'error'); opening = false; return end
            local chargeCount = commit.chargeIds and #commit.chargeIds or 0
            MZPoliceClient.SetPendingIntake({
              targetSource = targetSource,
              citizenid = commit.target and commit.target.citizenid or '',
              caseId = commit.caseId or '',
              chargeId = chargeCount > 1 and '' or (commit.chargeId or '')
            })
            local successMessage = ('Caso %s criado. Leve o custodiado ao intake.'):format(tostring(commit.caseId or ''))
            if type(commit.warnings) == 'table' and #commit.warnings > 0 then
              successMessage = successMessage .. ' A multa não foi registrada automaticamente; verifique o caso no MDT.'
            elseif tonumber(commit.totals and commit.totals.fineAmount) and tonumber(commit.totals.fineAmount) > 0 then
              successMessage = successMessage .. (' Multa pendente: %s.'):format(money(commit.totals.fineAmount))
            end
            notify(successMessage, 'success')
            opening = false
          end)
        end)
      end)
    end)
  end)
  return true
end
