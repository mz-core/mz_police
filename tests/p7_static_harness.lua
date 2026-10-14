local function read(path)
  local file = assert(io.open(path, 'rb'))
  local value = file:read('*a')
  file:close()
  return value
end
local function expect(condition, message) if not condition then error(message, 2) end end

local manifest, config = read('fxmanifest.lua'), read('server/config.lua')
local prison, bridge = read('server/prison.lua'), read('server/bridge.lua')

expect(manifest:find("'server/prison.lua'", 1, true), 'adapter prisional nao e carregado')
expect(not manifest:find("  'mz_prison',", 1, true), 'dependencia circular/ordem rigida com mz_prison')
expect(config:find('enabled = false', config:find('Prison = {', 1, true), true), 'integracao prisional nao esta fail-closed')
expect(prison:find('MZPolice.Custody.get', 1, true), 'custodia autoritativa nao e exigida')
expect(prison:find('GetPlayerRoutingBucket', 1, true) and prison:find('maximumDistance', 1, true), 'proximidade/bucket ausentes')
expect(prison:find('police.arrest.request', 1, true) == nil, 'capability foi hardcoded fora da configuracao')
expect(not prison:find('durationSeconds', 1, true), 'duracao foi aceita pelo adapter policial')
expect(bridge:find("'RequestSentence'", 1, true) and bridge:find("'RestorePrisonerProperty'", 1, true) == nil,
  'adapter ultrapassa o owner prisional')

print('mz_police P7 static harness: PASS cases=8')
