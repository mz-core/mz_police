MZPolice = MZPolice or {}

-- Persistencia OPCIONAL das algemas fisicas.
--
-- Nao cria schema automaticamente. A tabela deve ser criada manualmente a
-- partir de sql/restraints.sql e MZPoliceConfig.Restraints.persistence.enabled
-- deve ser true. Qualquer falha mantem a persistencia desligada (fail closed
-- para escrita; o runtime continua com o estado em memoria).

local Repository = {}
local state = { ready = false, reason = 'not_prepared', lastError = nil }

local function settings()
  local cfg = type(MZPoliceConfig.Restraints) == 'table' and MZPoliceConfig.Restraints or {}
  return type(cfg.persistence) == 'table' and cfg.persistence or {}
end

local function tableName()
  local name = tostring(settings().table or 'mz_police_restraints')
  if not name:match('^[%w_]+$') then return nil, 'invalid_table_name' end
  return name
end

local function logError(scope, err)
  local message = tostring(err or 'unknown')
  if state.lastError ~= message then
    state.lastError = message
    print(('[mz_police][restraints][persistence] %s: %s'):format(tostring(scope), message))
  end
end

function Repository.ready()
  return state.ready == true
end

function Repository.status()
  return {
    ready = state.ready == true,
    reason = state.reason,
    enabled = settings().enabled == true
  }
end

function Repository.prepare()
  if settings().enabled ~= true then
    state.ready, state.reason = false, 'disabled'
    return false, 'disabled'
  end
  if type(MySQL) ~= 'table' or type(MySQL.query) ~= 'table'
    or type(MySQL.query.await) ~= 'function' then
    state.ready, state.reason = false, 'mysql_unavailable'
    return false, 'mysql_unavailable'
  end
  local name, nameError = tableName()
  if not name then
    state.ready, state.reason = false, nameError
    return false, nameError
  end
  local ok, err = pcall(MySQL.query.await, ('SELECT 1 FROM %s LIMIT 1'):format(name))
  if not ok then
    state.ready, state.reason = false, 'table_unavailable'
    logError('prepare', err)
    return false, 'table_unavailable'
  end
  state.ready, state.reason, state.lastError = true, 'ready', nil
  print(('[mz_police][restraints][persistence] ready table=%s'):format(name))
  return true
end

local function stateToRow(value, status)
  local restraint = type(value.restraint) == 'table' and value.restraint or {}
  local target = type(value.target) == 'table' and value.target or {}
  local actor = type(value.cuffedBy) == 'table' and value.cuffedBy or {}
  local targetCitizenid = tostring(target.citizenid or '')
  local actorCitizenid = tostring(actor.citizenid or '')
  local restraintId = tostring(restraint.id or '')
  local cuffUid = tostring(restraint.itemUid or '')
  local cuffSerial = tostring(restraint.serial or '')
  if targetCitizenid == '' or actorCitizenid == '' or restraintId == ''
    or cuffUid == '' or cuffSerial == '' then
    return nil
  end
  return {
    target_citizenid = targetCitizenid,
    restraint_id = restraintId,
    target_character_id = tonumber(target.characterId),
    target_session_id = tonumber(target.sessionId),
    actor_citizenid = actorCitizenid,
    actor_character_id = tonumber(actor.characterId),
    actor_session_id = tonumber(actor.sessionId),
    origin = 'physical',
    status = tostring(status or 'active'),
    cuff_instance_uid = cuffUid,
    cuff_serial = cuffSerial,
    key_instance_uid = restraint.keyUid and tostring(restraint.keyUid) or nil,
    key_holder_citizenid = restraint.keyHolder and tostring(restraint.keyHolder) or nil,
    reason = restraint.reason and tostring(restraint.reason):sub(1, 255) or nil,
    revision = math.max(1, tonumber(value.revision) or 1),
    applied_at = tonumber(restraint.appliedAt) or os.time()
  }
end

function Repository.upsert(value, status)
  if state.ready ~= true then return false, 'not_ready' end
  local name = tableName()
  if not name then return false, 'invalid_table_name' end
  local row = stateToRow(value, status)
  if not row then return false, 'invalid_state' end
  local ok, err = pcall(MySQL.insert.await, ([[
INSERT INTO %s
  (target_citizenid, restraint_id, target_character_id, target_session_id,
   actor_citizenid, actor_character_id, actor_session_id, origin, status,
   cuff_instance_uid, cuff_serial, key_instance_uid, key_holder_citizenid,
   reason, revision, applied_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON DUPLICATE KEY UPDATE
  restraint_id = VALUES(restraint_id),
  target_character_id = VALUES(target_character_id),
  target_session_id = VALUES(target_session_id),
  actor_citizenid = VALUES(actor_citizenid),
  actor_character_id = VALUES(actor_character_id),
  actor_session_id = VALUES(actor_session_id),
  origin = VALUES(origin),
  status = VALUES(status),
  cuff_instance_uid = VALUES(cuff_instance_uid),
  cuff_serial = VALUES(cuff_serial),
  key_instance_uid = VALUES(key_instance_uid),
  key_holder_citizenid = VALUES(key_holder_citizenid),
  reason = VALUES(reason),
  revision = VALUES(revision),
  applied_at = VALUES(applied_at)
]]):format(name), {
    row.target_citizenid,
    row.restraint_id,
    row.target_character_id,
    row.target_session_id,
    row.actor_citizenid,
    row.actor_character_id,
    row.actor_session_id,
    row.origin,
    row.status,
    row.cuff_instance_uid,
    row.cuff_serial,
    row.key_instance_uid,
    row.key_holder_citizenid,
    row.reason,
    row.revision,
    row.applied_at
  })
  if not ok then
    logError('upsert', err)
    return false, 'write_failed'
  end
  return true
end

function Repository.remove(citizenid)
  if state.ready ~= true then return false, 'not_ready' end
  local name = tableName()
  if not name then return false, 'invalid_table_name' end
  local ok, err = pcall(MySQL.update.await,
    ('DELETE FROM %s WHERE target_citizenid = ?'):format(name), { tostring(citizenid or '') })
  if not ok then
    logError('remove', err)
    return false, 'write_failed'
  end
  return true
end

local function rowToState(row)
  if type(row) ~= 'table' then return nil end
  local targetCitizenid = tostring(row.target_citizenid or '')
  local restraintId = tostring(row.restraint_id or '')
  local cuffUid = tostring(row.cuff_instance_uid or '')
  local cuffSerial = tostring(row.cuff_serial or '')
  if targetCitizenid == '' or restraintId == '' or cuffUid == '' or cuffSerial == '' then
    return nil
  end
  return {
    revision = math.max(1, tonumber(row.revision) or 1),
    cuffed = true,
    target = {
      citizenid = targetCitizenid,
      characterId = tonumber(row.target_character_id),
      sessionId = tonumber(row.target_session_id),
      active = true
    },
    cuffedBy = {
      citizenid = tostring(row.actor_citizenid or ''),
      characterId = tonumber(row.actor_character_id),
      sessionId = tonumber(row.actor_session_id),
      active = true
    },
    restraint = {
      id = restraintId,
      origin = 'physical',
      itemUid = cuffUid,
      serial = cuffSerial,
      keyUid = row.key_instance_uid and tostring(row.key_instance_uid) or nil,
      keyHolder = row.key_holder_citizenid and tostring(row.key_holder_citizenid) or nil,
      appliedAt = tonumber(row.applied_at),
      persistent = true,
      actorOffline = true,
      reason = row.reason and tostring(row.reason) or nil
    }
  }
end

function Repository.get(citizenid)
  if state.ready ~= true then return nil end
  local name = tableName()
  if not name then return nil end
  local ok, row = pcall(MySQL.single.await,
    ('SELECT * FROM %s WHERE target_citizenid = ? LIMIT 1'):format(name),
    { tostring(citizenid or '') })
  if not ok then
    logError('get', row)
    return nil
  end
  return rowToState(row)
end

MZPolice.RestraintsRepository = Repository
