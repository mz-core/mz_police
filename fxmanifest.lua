fx_version 'cerulean'
game 'gta5'

name 'mz_police'
author 'Mazus / MZ Framework'
description 'Fundacao server-authoritative do dominio policial MZ'
version '0.2.0'

lua54 'yes'

server_scripts {
  'server/config.lua',
  'server/bridge.lua',
  'server/audit.lua',
  'server/policy.lua',
  'server/custody.lua',
  'server/search.lua',
  'server/events.lua',
  'server/main.lua',
  'server/p1_gate.lua'
}

client_scripts {
  'client/custody.lua'
}

dependencies {
  'mz_core',
  'mz_org',
  'mz_inventory'
}
