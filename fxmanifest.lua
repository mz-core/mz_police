fx_version 'cerulean'
game 'gta5'

name 'mz_police'
author 'Mazus / MZ Framework'
description 'Operacoes policiais server-authoritative do MZ Framework'
version '0.3.0'

lua54 'yes'

shared_scripts {
  'server/config.lua',
}

server_scripts {
  'server/bridge.lua',
  'server/audit.lua',
  'server/policy.lua',
  'server/custody.lua',
  'server/search.lua',
  'server/stations.lua',
  'server/enforcement.lua',
  'server/evidence.lua',
  'server/events.lua',
  'server/main.lua',
  'server/p1_gate.lua'
}

client_scripts {
  'client/custody.lua',
  'client/stations.lua',
  'client/enforcement.lua'
}

dependencies {
  'mz_core',
  'mz_org',
  'mz_inventory',
  'mz_interact',
  'mz_menu',
  'mz_garagem'
}
