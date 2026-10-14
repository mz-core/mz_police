local function expect(condition, message)
  if not condition then error(message, 2) end
end

local function readFile(path)
  local file = assert(io.open(path, 'rb'))
  local content = file:read('*a')
  file:close()
  return content
end

local manifest = readFile('fxmanifest.lua')
expect(manifest:find("name 'mz_police'", 1, true), 'manifest does not identify mz_police')
expect(manifest:find("'mz_core'", 1, true), 'manifest does not depend on mz_core')
expect(manifest:find("'mz_org'", 1, true), 'manifest does not depend on mz_org')
expect(manifest:find("'server/p1_gate.lua'", 1, true), 'manifest does not load the P1 runtime gate')
expect(not manifest:find('shared_script', 1, true), 'P1 unexpectedly loads shared/client scripts')
expect(not manifest:find('oxmysql', 1, true), 'P1 unexpectedly depends on persistence')

local policySource = readFile('server/policy.lua')
expect(not policySource:find('HasGlobalPermission', 1, true), 'policy mixes staff and police authorization')
expect(not policySource:find('RegisterNetEvent', 1, true), 'P1 unexpectedly exposes a network event')
local gateSource = readFile('server/p1_gate.lua')
expect(not gateSource:find('RegisterNetEvent', 1, true), 'P1 gate unexpectedly exposes a network event')
expect(not gateSource:find("exports(", 1, true), 'P1 gate unexpectedly exposes an export')
expect(gateSource:find("GetConvar('mz_police_p1_gate_enabled', '0')", 1, true),
  'P1 gate is not disabled by default')

local resourceStates = { mz_core = 'started', mz_org = 'started', mz_inventory = 'started' }
local readiness = { ready = true, terminal = false, reason = 'ready' }
local identities = {}
local organizations = {}
local capabilities = {}
local logs = {}
local events = {}
local commands = {}
local gateEnabled = '1'
local gateEnvironment = 'staging'

local function identity(sourceId, active)
  return {
    ok = true,
    source = sourceId,
    accountId = sourceId * 10,
    characterId = sourceId * 100,
    sessionId = sourceId * 1000,
    citizenid = ('CID%03d'):format(sourceId),
    active = active ~= false
  }
end

local function org(code, duty, active)
  return {
    orgId = code == 'police' and 1 or 2,
    code = code,
    type = 'job',
    active = active ~= false,
    status = active == false and 'archived' or 'active',
    duty = duty == true,
    grade = { id = 1, level = 1, code = 'recruta' }
  }
end

identities[1] = identity(1)
identities[2] = identity(2)
identities[4] = identity(4)
identities[5] = identity(5)
organizations[1] = { org('police', true) }
organizations[2] = { org('mafia', true) }
organizations[4] = { org('police', false) }
organizations[5] = { org('police', true, false) }
capabilities[1] = { ['org.view'] = true, ['staff.logs.view'] = true }
capabilities[4] = { ['org.view'] = true }
capabilities[5] = { ['org.view'] = true }

exports = {
  mz_core = {
    ResolvePlayerIdentity = function(_, sourceId)
      return identities[sourceId] or { ok = false, error = 'session_not_found' }
    end,
    CreateDetailedLog = function(_, scope, action, payload)
      logs[#logs + 1] = { scope = scope, action = action, payload = payload }
      return #logs
    end
  },
  mz_org = {
    GetOrganizationReadiness = function()
      return readiness
    end,
    GetPlayerOrgContext = function(_, sourceId)
      return organizations[sourceId] or {}
    end,
    CanOrg = function(_, sourceId, orgCode, capability)
      return orgCode == 'police'
        and capabilities[sourceId]
        and capabilities[sourceId][capability] == true
        or false
    end
  }
}

function GetResourceState(resourceName)
  return resourceStates[resourceName] or 'missing'
end

function GetCurrentResourceName()
  return 'mz_police'
end

function AddEventHandler(eventName, handler)
  events[eventName] = handler
end

function RegisterNetEvent(eventName)
  events[eventName] = events[eventName] or false
end

function TriggerClientEvent() end

function GetConvar(name, defaultValue)
  if name == 'mz_police_p1_gate_enabled' then return gateEnabled end
  if name == 'mz_police_environment' then return gateEnvironment end
  return defaultValue
end

function RegisterCommand(commandName, handler, restricted)
  commands[commandName] = { handler = handler, restricted = restricted }
end

dofile('server/config.lua')
dofile('server/bridge.lua')
dofile('server/audit.lua')
dofile('server/policy.lua')
dofile('server/custody.lua')
dofile('server/search.lua')
dofile('server/events.lua')
dofile('server/main.lua')
dofile('server/p1_gate.lua')

expect(MZPolice.Initialize() == true, 'resource initialization failed with dependencies available')
expect(logs[#logs].action == 'police.resource.started', 'resource initialization was not audited')
local ready, readinessError, readinessContract = MZPolice.Bridge.organizationReady()
expect(ready == true and readinessError == nil and readinessContract.reason == 'ready',
  'organization readiness contract was not preserved')

local decision = MZPolice.Policy.authorize(1, 'org.view')
expect(decision.ok == true and decision.code == 'authorized', 'valid police session was denied')
expect(decision.identity.citizenid == 'CID001' and decision.identity.sessionId == 1000,
  'authorization did not resolve canonical identity/session')
expect(decision.organization.code == 'police' and decision.organization.duty == true,
  'authorization returned the wrong organization context')

decision = MZPolice.Policy.authorize(2, 'org.view')
expect(decision.ok == false and decision.code == 'police_organization_not_found',
  'non-police organization was authorized')

decision = MZPolice.Policy.authorize(1, 'police.unknown')
expect(decision.ok == false and decision.code == 'capability_denied',
  'unknown capability was authorized')

decision = MZPolice.Policy.authorize(4, 'org.view')
expect(decision.ok == false and decision.code == 'duty_required', 'off-duty police was authorized')
expect(logs[#logs].payload.context.orgCode == 'police', 'duty denial lost authoritative org context')
local logsAfterDutyDenial = #logs
MZPolice.Policy.authorize(4, 'org.view')
expect(#logs == logsAfterDutyDenial, 'repeated denial bypassed audit throttling')

decision = MZPolice.Policy.authorize(1, 'staff.logs.view')
expect(decision.ok == false and decision.code == 'staff_capability_forbidden',
  'staff permission was treated as police authority')

decision = MZPolice.Policy.authorize(1, 'org.view', { citizenid = 'FORGED', duty = true })
expect(decision.ok == false and decision.code == 'invalid_context',
  'forged identity/duty context was accepted')

decision = MZPolice.Policy.authorize(1, 'org.view', { orgCode = 'mafia' })
expect(decision.ok == false and decision.code == 'organization_not_authorized',
  'unconfigured organization was accepted')

decision = MZPolice.Policy.authorize(3, 'org.view')
expect(decision.ok == false and decision.code == 'session_not_found',
  'missing session did not fail closed')

identities[6] = identity(6, false)
organizations[6] = { org('police', true) }
capabilities[6] = { ['org.view'] = true }
decision = MZPolice.Policy.authorize(6, 'org.view')
expect(decision.ok == false and decision.code == 'character_not_active',
  'inactive character was authorized')

decision = MZPolice.Policy.authorize(5, 'org.view')
expect(decision.ok == false and decision.code == 'police_organization_not_found',
  'archived police organization was authorized')

resourceStates.mz_core = 'missing'
decision = MZPolice.Policy.authorize(1, 'org.view')
expect(decision.ok == false and decision.code == 'core_unavailable',
  'missing core dependency did not fail closed')
resourceStates.mz_core = 'started'

resourceStates.mz_org = 'missing'
decision = MZPolice.Policy.authorize(1, 'org.view')
expect(decision.ok == false and decision.code == 'organization_unavailable',
  'missing organization dependency did not fail closed')
resourceStates.mz_org = 'started'

readiness = { ready = false, terminal = false, reason = 'organization_seed_pending' }
decision = MZPolice.Policy.authorize(1, 'org.view')
expect(decision.ok == false and decision.code == 'organization_not_ready',
  'unready organization owner did not fail closed')
readiness = { ready = true, terminal = false, reason = 'ready' }

events.playerDropped()
events.onResourceStart('another_resource')
events.onResourceStart('mz_police')
expect(logs[#logs].action == 'police.resource.started', 'resource start handler did not initialize P1')

local gateCommand = commands.mz_police_p1_gate
expect(gateCommand and gateCommand.restricted == true, 'P1 gate command is not registered as restricted')
local logsBeforePlayerCommand = #logs
gateCommand.handler(1, { 'probe', '1', 'org.view', 'police' })
expect(#logs == logsBeforePlayerCommand, 'player invocation reached the console-only P1 gate')
gateCommand.handler(0, { 'status' })
gateCommand.handler(0, { 'probe', '1', 'org.view', 'police' })
expect(logs[#logs].action == 'police.p1_gate.probe', 'P1 gate probe was not audited')
expect(logs[#logs].payload.meta.decision == 'authorized'
  and logs[#logs].payload.meta.identity == 'ok'
  and logs[#logs].payload.meta.membership == 'found'
  and logs[#logs].payload.meta.duty == true
  and logs[#logs].payload.meta.dutyPoint == 'missing'
  and logs[#logs].payload.meta.canOrg == true,
  'P1 gate did not preserve real-contract evidence fields')

resourceStates.mz_org = 'missing'
decision = MZPolice.P1Gate.probe(1, 'org.view', 'police')
expect(decision.ok == false and decision.code == 'organization_unavailable',
  'P1 gate did not expose the missing organization dependency')
resourceStates.mz_org = 'started'

resourceStates.mz_core = 'missing'
decision = MZPolice.P1Gate.probe(1, 'org.view', 'police')
expect(decision.ok == false and decision.code == 'core_unavailable',
  'P1 gate did not expose the missing core dependency')
resourceStates.mz_core = 'started'

commands = {}
MZPolice.P1Gate = nil
gateEnabled = '0'
dofile('server/p1_gate.lua')
expect(commands.mz_police_p1_gate == nil and MZPolice.P1Gate == nil,
  'P1 gate registered while disabled')

commands = {}
gateEnabled = '1'
gateEnvironment = 'production'
dofile('server/p1_gate.lua')
expect(commands.mz_police_p1_gate == nil and MZPolice.P1Gate == nil,
  'P1 gate registered outside staging')

print('mz_police P1 harness: PASS cases=23')
