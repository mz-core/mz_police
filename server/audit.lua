MZPolice = MZPolice or {}

local Audit = {}
local denialWindows = {}

local function cooldownSeconds()
  return math.max(1, math.floor(tonumber(MZPoliceConfig.RejectionLogCooldownSeconds) or 30))
end

local function shouldLog(decision)
  local source = tonumber(decision.source)
  local identity = type(decision.identity) == 'table' and decision.identity or nil
  if not source or not identity or not identity.sessionId or not identity.citizenid then return false end

  local bucket = denialWindows[source] or {}
  denialWindows[source] = bucket
  local key = table.concat({
    tostring(identity.sessionId),
    tostring(decision.code or 'denied'),
    tostring(decision.capability or ''),
    tostring(decision.orgCode or '')
  }, ':')
  local now = os.time()

  if bucket[key] and now - bucket[key] < cooldownSeconds() then return false end
  bucket[key] = now
  return true
end

function Audit.denied(decision)
  if not shouldLog(decision) then return false, 'throttled_or_unresolved' end

  local identity = decision.identity
  return MZPolice.Bridge.createDetailedLog('police.authorization.denied', {
    actor = {
      type = 'character',
      id = identity.citizenid,
      citizenid = identity.citizenid
    },
    context = {
      orgCode = decision.orgCode,
      capability = decision.capability
    },
    meta = {
      decision = decision.code
    }
  })
end

function Audit.started(organizationReady)
  return MZPolice.Bridge.createDetailedLog('police.resource.started', {
    actor = { type = 'system', id = 'mz_police' },
    meta = {
      phase = 'P1',
      organizationReady = organizationReady == true
    }
  })
end

function Audit.custody(action, actor, target, fields)
  fields = type(fields) == 'table' and fields or {}
  return MZPolice.Bridge.createDetailedLog(('police.custody.%s'):format(tostring(action)), {
    actor = {
      type = 'character',
      id = actor.citizenid,
      citizenid = actor.citizenid
    },
    target = {
      type = 'character',
      id = target.citizenid,
      citizenid = target.citizenid
    },
    context = {
      orgCode = fields.orgCode,
      capability = fields.capability
    },
    meta = {
      requestId = fields.requestId,
      revision = fields.revision,
      result = fields.result,
      reason = fields.reason
    }
  })
end

function Audit.custodyCleanup(target, fields)
  fields = type(fields) == 'table' and fields or {}
  return MZPolice.Bridge.createDetailedLog('police.custody.cleanup', {
    actor = { type = 'system', id = 'mz_police' },
    target = {
      type = 'character',
      id = target.citizenid,
      citizenid = target.citizenid
    },
    meta = {
      revision = fields.revision,
      reason = fields.reason
    }
  })
end

function Audit.armory(action, actor, fields)
  fields = type(fields) == 'table' and fields or {}
  return MZPolice.Bridge.createDetailedLog(('police.armory.%s'):format(tostring(action)), {
    actor = { type = 'character', id = actor.citizenid, citizenid = actor.citizenid },
    context = {
      orgCode = fields.orgCode,
      stationId = fields.stationId,
      operationId = fields.operationId
    },
    meta = {
      catalogKey = fields.catalogKey,
      item = fields.item,
      instanceUid = fields.instanceUid,
      result = fields.result,
      reason = fields.reason
    }
  })
end

function Audit.clearSource(source)
  source = tonumber(source)
  if source then denialWindows[source] = nil end
end

MZPolice.Audit = Audit
