fx_version 'cerulean'
game 'gta5'

name 'mz_police'
author 'Mazus / MZ Framework'
description 'Operacoes policiais server-authoritative do MZ Framework'
version '0.7.0'

lua54 'yes'

shared_scripts {
  'server/config.lua',
}

server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'server/bridge.lua',
  'server/audit.lua',
  'server/policy.lua',
  'server/records_prepare.lua',
  'server/records_repository.lua',
  'server/custody.lua',
  'server/search.lua',
  'server/stations.lua',
  'server/enforcement.lua',
  'server/evidence.lua',
  'server/records.lua',
  'server/prison.lua',
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
  'oxmysql',
  'mz_core',
  'mz_org',
  'mz_economy',
  'mz_inventory',
  'mz_interact',
  'mz_menu',
  'mz_garagem'
}
