local function read(path)
  local file = assert(io.open(path, 'rb'), path)
  local value = file:read('*a')
  file:close()
  return value
end
local function expect(condition, message) if not condition then error(message, 2) end end

local manifest = read('fxmanifest.lua')
local config = read('server/config.lua')
local enforcement = read('server/enforcement.lua')
local client = read('client/enforcement.lua')
local bridge = read('server/bridge.lua')

expect(config:find('flags = {}', 1, true), 'flags legais foram inventadas')
expect(manifest:find("'mz_vehicles'", 1, true), 'dependencia direta mz_vehicles ausente')
expect(config:find('impoundReasons = {}', 1, true), 'motivos de impound foram inventados')
expect(config:find('types = {}', 1, true), 'modelos de objetos viarios foram inventados')
expect(enforcement:find('closed(payload, IMPOUND_KEYS)', 1, true), 'payload de impound nao e fechado')
expect(enforcement:find('CreateObjectNoOffset', 1, true), 'objeto nao e criado no servidor')
expect(bridge:find("'PoliceImpoundScannedVehicle'", 1, true), 'impound nao delega ao owner veicular')
expect(not client:find('SetVehicle', 1, true), 'client assumiu autoridade veicular')

print('mz_police P4 static harness: PASS')
