MZPoliceClient = MZPoliceClient or {}

local activePanel
local panelSequence = 0

local function notify(message, kind, title)
  local noticeType = ({ success = 'success', error = 'error', warning = 'warning', info = 'info', inform = 'info' })[kind] or 'info'
  if GetResourceState('mz_lib') == 'started' then
    local ok = pcall(function() exports['mz_lib']:notify({
      type = noticeType,
      title = tostring(title or 'MZ Police'),
      description = tostring(message or ''),
      duration = 5000
    }) end)
    if ok then return true end
  end
  print(('[mz_police] %s'):format(tostring(message)))
  return false
end

local function releaseFocus()
  if type(MZPoliceClient.IsMdtOpen) ~= 'function' or MZPoliceClient.IsMdtOpen() ~= true then
    SetNuiFocus(false, false)
  end
end

local function closePanel(runClose)
  local previous = activePanel
  if not previous then return end
  activePanel = nil
  SendNUIMessage({ type = 'panel:close', panelId = previous.id })
  releaseFocus()
  if runClose and type(previous.onClose) == 'function' then previous.onClose() end
end

local function publicSpec(spec, panelId)
  local public = {
    id = panelId,
    kind = tostring(spec.kind or 'list'),
    title = tostring(spec.title or 'MZ Police'),
    subtitle = tostring(spec.subtitle or ''),
    confirmLabel = tostring(spec.confirmLabel or 'Confirmar'),
    cancelLabel = tostring(spec.cancelLabel or 'Cancelar'),
    options = {},
    fields = {}
  }
  for index, option in ipairs(type(spec.options) == 'table' and spec.options or {}) do
    public.options[index] = {
      id = tostring(index),
      title = tostring(option.title or ''),
      description = tostring(option.description or ''),
      icon = tostring(option.icon or 'chevron-right'),
      disabled = option.disabled == true or option.readOnly == true,
      destructive = option.destructive == true
    }
  end
  for index, field in ipairs(type(spec.fields) == 'table' and spec.fields or {}) do
    local options = {}
    for optionIndex, option in ipairs(type(field.options) == 'table' and field.options or {}) do
      options[optionIndex] = {
        value = tostring(option.value or ''), label = tostring(option.label or option.value or '')
      }
    end
    public.fields[index] = {
      type = tostring(field.type or 'text'),
      label = tostring(field.label or ''),
      placeholder = tostring(field.placeholder or ''),
      default = field.default,
      required = field.required == true,
      min = tonumber(field.min),
      max = tonumber(field.max),
      options = options
    }
  end
  return public
end

local function openPanel(spec, callback)
  if type(spec) ~= 'table' then return false end
  closePanel(true)
  panelSequence = panelSequence + 1
  local panelId = ('police_panel:%s:%s'):format(GetGameTimer(), panelSequence)
  activePanel = {
    id = panelId,
    spec = spec,
    callback = type(callback) == 'function' and callback or nil,
    onClose = type(spec.onClose) == 'function' and spec.onClose or nil
  }
  SetNuiFocus(true, true)
  SendNUIMessage({ type = 'panel:open', panel = publicSpec(spec, panelId) })
  return true
end

RegisterNUICallback('policePanelSubmit', function(data, callback)
  data = type(data) == 'table' and data or {}
  local panel = activePanel
  if not panel or tostring(data.panelId or '') ~= panel.id then
    callback({ ok = false, code = 'invalid_panel' })
    return
  end
  local kind = tostring(panel.spec.kind or 'list')
  local result
  if kind == 'list' then
    local index = math.floor(tonumber(data.actionId) or 0)
    local option = type(panel.spec.options) == 'table' and panel.spec.options[index] or nil
    if not option or option.disabled == true or option.readOnly == true or type(option.onSelect) ~= 'function' then
      callback({ ok = false, code = 'invalid_action' })
      return
    end
    result = option.onSelect
  elseif kind == 'confirm' then
    result = data.confirmed == true
  else
    result = type(data.values) == 'table' and data.values or {}
  end
  local onSubmit = panel.callback
  closePanel(false)
  callback({ ok = true })
  if kind == 'list' then result() elseif onSubmit then onSubmit(result) end
end)

RegisterNUICallback('policePanelClose', function(data, callback)
  local panelId = type(data) == 'table' and tostring(data.panelId or '') or ''
  if activePanel and panelId == activePanel.id then closePanel(true) end
  callback({ ok = true })
end)

MZPoliceClient.Notify = notify
MZPoliceClient.Panel = { Open = openPanel, Close = function() closePanel(true) end }

AddEventHandler('onClientResourceStop', function(resourceName)
  if resourceName ~= GetCurrentResourceName() then return end
  activePanel = nil
  SetNuiFocus(false, false)
end)
