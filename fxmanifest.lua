fx_version 'cerulean'
game 'gta5'

name 'mz_police'
author 'Mazus / MZ Framework'
description 'Operacoes policiais server-authoritative do MZ Framework'
version '0.11.0'

lua54 'yes'

shared_scripts {
  '@ox_lib/init.lua',
  'config/shared.lua',
}

server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'config/server.lua',
  'config/penal_code.lua',
  'server/bridge.lua',
  'server/audit.lua',
  'server/policy.lua',
  'server/tracker_v2.lua',
  'server/records/schema.lua',
  'server/records/repository.lua',
  'server/custody.lua',
  'server/restraints/repository.lua',
  'server/restraints/service.lua',
  'server/items.lua',
  'server/search.lua',
  'server/third_party_inventory.lua',
  'server/stations.lua',
  'server/enforcement.lua',
  'server/evidence.lua',
  'server/records/service.lua',
  'server/prison.lua',
  'server/arrest.lua',
  'server/advanced.lua',
  'server/interactions.lua',
  'server/events.lua',
  'server/commands.lua',
  'server/main.lua'
}

client_scripts {
  'client/panel.lua',
  'client/custody.lua',
  'client/stations.lua',
  'client/enforcement.lua',
  'client/mdt.lua',
  'client/advanced.lua',
  'client/tracker.lua',
  'client/air_camera.lua',
  'client/arrest.lua',
  'client/interactions.lua',
  'client/restraints.lua',
  'client/target.lua',
  'client/radialmenu.lua'
}

ui_page 'web/index.html'

files {
  'web/index.html',
  'web/style.css',
  'web/lucide.min.js',
  'web/tracker_math.js',
  'web/app.js',
  'locales/*.json'
}

dependencies {
  'ox_lib',
  'oxmysql',
  'mz_core',
  'mz_org',
  'mz_economy',
  'mz_inventory',
  'mz_vehicles',
  'mz_navigation',
  'mz_interact',
  'mz_garagem'
}
