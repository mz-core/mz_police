local function read(path)
  local file = assert(io.open(path, 'rb'), path)
  local value = file:read('*a')
  file:close()
  return value
end

local function expect(condition, message)
  if not condition then error(message, 2) end
end

local manifest = read('fxmanifest.lua')
local config = read('server/config.lua')
local stations = read('server/stations.lua')
local client = read('client/stations.lua')
local custody = read('server/custody.lua')

for _, dependency in ipairs({ 'mz_inventory', 'mz_interact', 'mz_menu', 'mz_garagem' }) do
  expect(manifest:find("'" .. dependency .. "'", 1, true), 'dependencia P3 ausente: ' .. dependency)
end
expect(config:find('Stations = {}', 1, true), 'P3 inventou uma estacao/coordenada padrao')
expect(config:find('catalog = {}', 1, true), 'P3 inventou um catalogo de arsenal')
expect(stations:find('closedPayload(payload, ISSUE_KEYS)', 1, true), 'payload de emissao nao e fechado')
expect(stations:find('MZPolice.Policy.authorize', 1, true), 'arsenal nao revalida policy no servidor')
expect(client:find("exports['mz_interact']:AddPoint", 1, true), 'ponto nao usa mz_interact')
expect(client:find("exports['mz_menu']:OpenContext", 1, true), 'arsenal nao usa mz_menu')
expect(custody:find('MZPolice.Stations.sweep()', 1, true), 'terminais P3 nao possuem cleanup')
expect(not (stations .. client):find('GiveWeaponToPed', 1, true), 'arsenal entrega arma fora do inventory')

print('mz_police P3 static harness: PASS')
