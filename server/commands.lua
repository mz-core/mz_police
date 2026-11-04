MZPolice = MZPolice or {}

-- Comandos server-authoritative de restricoes. Todos revalidam identidade,
-- duty, permissao Staff, alvo, distancia, bucket e estado no servidor.

local sequence = 0

local function requestId(prefix, source, targetSource)
  sequence = sequence + 1
  return ('%s:%s:%s:%s'):format(
    tostring(prefix or 'cmd'),
    tostring(source),
    tostring(targetSource or 0),
    tostring(sequence)
  )
end

local function parseTarget(args)
  local targetSource = tonumber(args and args[1])
  if not targetSource or targetSource <= 0 or targetSource % 1 ~= 0 then return nil end
  return targetSource
end

local function parseReason(args)
  local parts = {}
  for index = 2, #(args or {}) do
    parts[#parts + 1] = tostring(args[index])
  end
  local reason = table.concat(parts, ' '):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
  if #reason < 2 then return nil end
  return reason:sub(1, 200)
end

local function notify(source, action, targetSource, response)
  TriggerClientEvent('mz_police:client:restraints:result', source, {
    action = action,
    targetSource = targetSource,
    response = response
  })
end

local function usage(source, action, code)
  notify(source, action, nil, { ok = false, code = code })
end

local function run(source, args, action, channel, prefix, codePrefix)
  source = tonumber(source)
  if not source or source <= 0 then return end
  if type(MZPolice.Restraints) ~= 'table' then
    notify(source, action, nil, { ok = false, code = 'restraints_unavailable' })
    return
  end
  local targetSource = parseTarget(args)
  if not targetSource then
    usage(source, action, codePrefix .. '_usage')
    return
  end
  local reason = channel == 'admin' and parseReason(args) or nil
  local expectedRevision = MZPolice.Restraints.revision(targetSource) or 0
  local response = MZPolice.Restraints.request(source, {
    action = action,
    targetSource = targetSource,
    requestId = requestId(prefix, source, targetSource),
    expectedRevision = expectedRevision,
    reason = reason,
    command = prefix
  }, channel)
  notify(source, action, targetSource, response)
end

RegisterCommand('algemar', function(source, args)
  run(source, args, 'cuff', 'service', 'cmd_algemar', 'algemar')
end, false)

RegisterCommand('desalgemar', function(source, args)
  run(source, args, 'uncuff', 'service', 'cmd_desalgemar', 'desalgemar')
end, false)

RegisterCommand('staffalgemar', function(source, args)
  run(source, args, 'cuff', 'admin', 'cmd_staffalgemar', 'staffalgemar')
end, false)

RegisterCommand('staffdesalgemar', function(source, args)
  run(source, args, 'uncuff', 'admin', 'cmd_staffdesalgemar', 'staffdesalgemar')
end, false)
