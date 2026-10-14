MZPolice = MZPolice or {}

local Policy = {}

local function normalizeCapability(value)
  if type(value) ~= 'string' then return nil end
  value = value:gsub('^%s+', ''):gsub('%s+$', '')
  if value == '' or #value > 128 or value ~= value:lower() then return nil end
  if not value:match('^[a-z][a-z0-9_.-]*$') then return nil end
  return value
end

local function normalizeOrgCode(value)
  if type(value) ~= 'string' then return nil end
  value = value:gsub('^%s+', ''):gsub('%s+$', '')
  if value == '' or #value > 64 or value ~= value:lower() then return nil end
  if not value:match('^[a-z0-9][a-z0-9_-]*$') then return nil end
  return value
end

local function normalizeContext(value)
  if value == nil then return {} end
  if type(value) ~= 'table' then return nil end

  for key in pairs(value) do
    if key ~= 'orgCode' then return nil end
  end

  if value.orgCode == nil then return {} end
  local orgCode = normalizeOrgCode(value.orgCode)
  if not orgCode then return nil end
  return { orgCode = orgCode }
end

local function result(ok, code, extra)
  local out = { ok = ok == true, code = code }
  for key, value in pairs(extra or {}) do out[key] = value end
  return out
end

local function deny(code, source, capability, identity, orgCode)
  MZPolice.Audit.denied({
    code = code,
    source = source,
    capability = capability,
    identity = identity,
    orgCode = orgCode
  })
  return result(false, code, { capability = capability, orgCode = orgCode })
end

local function organizationCode(org)
  return type(org) == 'table' and normalizeOrgCode(org.code or org.orgCode or org.org_code) or nil
end

local function organizationActive(org)
  if type(org) ~= 'table' or org.active ~= true then return false end
  return org.status == nil or tostring(org.status):lower() == 'active'
end

local function organizationSnapshot(org, code)
  local grade = type(org.grade) == 'table' and org.grade or {}
  return {
    id = tonumber(org.orgId or org.org_id),
    code = code,
    type = tostring(org.type or ''),
    duty = org.duty == true,
    grade = {
      id = tonumber(grade.id),
      level = tonumber(grade.level or org.gradeLevel),
      code = tostring(grade.code or org.gradeCode or '')
    }
  }
end

function Policy.authorize(source, capability, context)
  source = tonumber(source)
  if not source or source <= 0 then return result(false, 'invalid_source') end

  capability = normalizeCapability(capability)
  if not capability then return result(false, 'invalid_capability') end
  if capability:match('^staff%.') then return result(false, 'staff_capability_forbidden') end

  context = normalizeContext(context)
  if not context then return result(false, 'invalid_context', { capability = capability }) end
  if context.orgCode and MZPoliceConfig.AuthorizedOrganizations[context.orgCode] ~= true then
    return result(false, 'organization_not_authorized', {
      capability = capability,
      orgCode = context.orgCode
    })
  end

  local identity, identityError = MZPolice.Bridge.resolveIdentity(source)
  if not identity then return result(false, identityError or 'identity_unavailable', { capability = capability }) end

  local ownerReady, readinessError = MZPolice.Bridge.organizationReady()
  if ownerReady ~= true then
    return deny(readinessError or 'organization_unavailable', source, capability, identity, context.orgCode)
  end

  local organizations, organizationsError = MZPolice.Bridge.getPlayerOrganizations(source)
  if not organizations then
    return deny(organizationsError or 'organization_unavailable', source, capability, identity, context.orgCode)
  end

  local capabilityDenied = false
  local dutyDenied = false
  local deniedOrgCode

  for _, org in ipairs(organizations) do
    local code = organizationCode(org)
    local selected = code
      and MZPoliceConfig.AuthorizedOrganizations[code] == true
      and (not context.orgCode or context.orgCode == code)

    if selected and organizationActive(org) then
      local allowed, permissionError = MZPolice.Bridge.canOrganization(source, code, capability)
      if allowed == nil then
        return deny(permissionError or 'organization_unavailable', source, capability, identity, code)
      end

      if allowed ~= true then
        capabilityDenied = true
        deniedOrgCode = deniedOrgCode or code
      elseif org.duty ~= true then
        dutyDenied = true
        deniedOrgCode = deniedOrgCode or code
      else
        return result(true, 'authorized', {
          source = source,
          capability = capability,
          identity = identity,
          organization = organizationSnapshot(org, code)
        })
      end
    end
  end

  if dutyDenied then return deny('duty_required', source, capability, identity, deniedOrgCode or context.orgCode) end
  if capabilityDenied then return deny('capability_denied', source, capability, identity, deniedOrgCode or context.orgCode) end
  return deny('police_organization_not_found', source, capability, identity, context.orgCode)
end

MZPolice.Policy = Policy
