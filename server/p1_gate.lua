MZPolice = MZPolice or {}

local COMMAND = 'mz_police_p1_gate'
local PREFIX = '[mz_police][P1_GATE]'

local enabled = GetConvar('mz_police_p1_gate_enabled', '0') == '1'
local staging = tostring(GetConvar('mz_police_environment', '')):lower() == 'staging'
if not enabled or not staging then return end

local function findOrganization(organizations, requestedCode)
  for _, organization in ipairs(organizations or {}) do
    local code = tostring(organization.code or organization.orgCode or organization.org_code or ''):lower()
    if code ~= '' and (code == requestedCode
      or (not requestedCode and MZPoliceConfig.AuthorizedOrganizations[code] == true)) then
      return organization, code
    end
  end
  return nil, requestedCode
end

local function dutyPointState(organization)
  local config = type(organization) == 'table' and organization.config or nil
  local point = type(config) == 'table' and config.dutyPoint or nil
  if type(point) ~= 'table' then return 'missing' end
  return point.enabled == true and 'enabled_unverified' or 'disabled'
end

local function status()
  local ready, readinessError, readiness = MZPolice.Bridge.organizationReady()
  readiness = type(readiness) == 'table' and readiness or {}
  print(('%s STATUS core=%s org=%s ready=%s terminal=%s reason=%s error=%s'):format(
    PREFIX,
    tostring(GetResourceState('mz_core')),
    tostring(GetResourceState('mz_org')),
    tostring(ready == true),
    tostring(readiness.terminal == true),
    tostring(readiness.reason or ''),
    tostring(readinessError or '')
  ))
end

local function probe(sourceId, capability, requestedCode)
  local identity, identityError = MZPolice.Bridge.resolveIdentity(sourceId)
  local ready, readinessError, readiness = MZPolice.Bridge.organizationReady()
  readiness = type(readiness) == 'table' and readiness or {}

  local organizations, organizationsError
  if identity then organizations, organizationsError = MZPolice.Bridge.getPlayerOrganizations(sourceId) end
  local organization, orgCode = findOrganization(organizations, requestedCode)
  local dutyPoint = dutyPointState(organization)

  local allowed, capabilityError
  if organization and orgCode then
    allowed, capabilityError = MZPolice.Bridge.canOrganization(sourceId, orgCode, capability)
  end

  local context = requestedCode and { orgCode = requestedCode } or nil
  local decision = MZPolice.Policy.authorize(sourceId, capability, context)
  local actor = identity and {
    type = 'character', id = identity.citizenid, citizenid = identity.citizenid
  } or { type = 'system', id = 'mz_police_p1_gate' }
  local auditId, auditError = MZPolice.Bridge.createDetailedLog('police.p1_gate.probe', {
    actor = actor,
    context = { orgCode = orgCode, capability = capability },
    meta = {
      source = sourceId,
      sessionId = identity and identity.sessionId or nil,
      characterId = identity and identity.characterId or nil,
      identity = identity and 'ok' or identityError,
      readiness = ready == true and 'ready' or readinessError,
      readinessReason = readiness.reason,
      organizationContext = type(organizations) == 'table' and 'ok' or organizationsError,
      organizationCount = type(organizations) == 'table' and #organizations or 0,
      membership = organization and 'found' or 'missing',
      duty = organization and organization.duty == true or false,
      dutyPoint = dutyPoint,
      canOrg = allowed,
      canOrgError = capabilityError,
      decision = decision.code
    }
  })

  print(('%s PROBE source=%s identity=%s account=%s character=%s session=%s ready=%s reason=%s org_context=%s org_count=%s org=%s membership=%s duty=%s duty_point=%s capability=%s can_org=%s can_org_error=%s policy=%s audit=%s audit_error=%s'):format(
    PREFIX,
    tostring(sourceId),
    tostring(identity and 'ok' or identityError),
    tostring(identity and identity.accountId or ''),
    tostring(identity and identity.characterId or ''),
    tostring(identity and identity.sessionId or ''),
    tostring(ready == true),
    tostring(readiness.reason or readinessError or ''),
    tostring(type(organizations) == 'table' and 'ok' or organizationsError or 'skipped'),
    tostring(type(organizations) == 'table' and #organizations or 0),
    tostring(orgCode or ''),
    tostring(organization and 'found' or 'missing'),
    tostring(organization and organization.duty == true or false),
    tostring(dutyPoint),
    tostring(capability),
    tostring(allowed),
    tostring(capabilityError or ''),
    tostring(decision.code),
    tostring(auditId or ''),
    tostring(auditError or '')
  ))

  return decision
end

MZPolice.P1Gate = { status = status, probe = probe }

RegisterCommand(COMMAND, function(source, args)
  if tonumber(source) ~= 0 then
    print(('%s BLOCKED reason=console_only'):format(PREFIX))
    return
  end

  local action = tostring(args and args[1] or ''):lower()
  if action == 'status' then
    status()
    return
  end

  local sourceId = tonumber(args and args[2])
  local capability = tostring(args and args[3] or 'org.view')
  local orgCode = args and args[4] and tostring(args[4]):lower() or nil
  if action ~= 'probe' or not sourceId or sourceId <= 0 then
    print(('%s USAGE %s status | %s probe <player_source> [capability] [org_code]'):format(
      PREFIX, COMMAND, COMMAND
    ))
    return
  end

  probe(sourceId, capability, orgCode)
end, true)

print(('%s enabled for staging; console-only command=%s'):format(PREFIX, COMMAND))
