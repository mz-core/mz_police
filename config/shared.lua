-- Configuracao carregada no cliente e no servidor.
-- Somente valores necessarios aos dois lados devem entrar neste arquivo.
-- Autoridade, permissoes, persistencia e catalogos ficam em config/server.lua
-- e config/penal_code.lua.

MZPoliceConfig = MZPoliceConfig or {}

-- Fonte unica das distancias de interact/target de custodia.
local TARGET_DISTANCE = 2.5

MZPoliceConfig.Interactions = {
  targetDistance = TARGET_DISTANCE
}

-- Diagnostico temporario. Em producao os logs detalhados ficam desligados;
-- erros reais e auditoria continuam sendo registrados no servidor.
MZPoliceConfig.Debug = {
  targetStatus = false,
  verboseErrors = false
}

-- O toast de NOVO chamado e emitido uma unica vez pelo owner mz_dispatch via
-- mz_notify. O evento newCall somente invalida o snapshot local da fila.
MZPoliceConfig.Dispatch = {
  debug = false,
  seenCallLimit = 128
}

-- Algemas, chaves e restricoes. O owner canonico do estado de custodia e o
-- servidor; este bloco tambem e lido pelo cliente para animacao e bloqueios.
MZPoliceConfig.Restraints = {
  enabled = true,
  capability = 'police.custody',
  staffPermission = 'staff.restraints.manage',
  enablePoliceCommand = true,
  enableStaffCommand = true,
  policeServiceCuffsWithoutItem = true,
  policeServiceUnlock = true,
  civilianPhysicalCuffs = true,
  civiliansRequireSurrenderedTarget = false,
  allowFrontCuff = false,
  maximumDistance = TARGET_DISTANCE,
  animationDurationMs = 1800,
  removalDurationMs = 900,
  applyTimeoutMs = 6000,
  cooldownMs = 750,
  rateLimit = { maximum = 6, windowMs = 5000 },
  requestRetentionMs = 120000,
  restrictVehicleEntry = true,
  blockWeaponUse = true,
  blockAttack = true,
  inventoryWhileCuffed = false,
  allowWalk = true,
  logStaffOverrides = true,
  items = {
    handcuffs = 'handcuffs',
    key = 'handcuff_key'
  },
  -- Persistencia e opcional e desativada por padrao. Requer o SQL
  -- sql/restraints.sql aplicado manualmente e a tabela existente.
  persistence = {
    enabled = false,
    table = 'mz_police_restraints',
    retryIntervalMs = 30000
  }
}

-- O servidor complementa esta tabela com TTL e rate limit.
MZPoliceConfig.Search = {
  defaultEvidenceContainer = 'intake',
  thirdPartyInventoryEnabled = false -- habilitar em staging apos homologacao FXServer
}

--[[
  Tracker V2 (stream autorizado server -> cliente -> NUI).

  DESLIGADO por padrao. Com Enabled=false, o tracker antigo
  (trackerSnapshot + blips nativos) continua exatamente como esta.
  A ativacao exige reinicio e testes FiveM/OneSync em homologacao.

  As capabilities e modelos continuam em MZPoliceConfig.Advanced.Tracker.
]]
MZPoliceConfig.TrackerV2 = {
  Enabled = false,
  -- Cadencia do stream e do RAF/buffer no cliente.
  TickMs = 1000,
  UnitAuthTtlMs = 3000,
  ViewerAuthTtlMs = 3000,
  -- Mapa/POIs so sao reenviados quando o cliente pede ou o cache expira.
  MapCacheMs = 60000,
  MaxUnits = 100,
  StaleAfterMs = 5000,
  -- Distancia (GTA units) acima da qual o render faz snap em vez de animar.
  TeleportThreshold = 250.0,
  -- Blips nativos sao apenas uma visao auxiliar; a NUI e a visao suave.
  NativeIntervalMs = 150,
  NativeInterpolation = true,
  Debug = false
}

-- Vazio por padrao: coordenadas reais devem ser configuradas pelo operador.
MZPoliceConfig.Stations = {}

-- Tipos sao lidos pelo cliente; capability e limites ficam no servidor.
MZPoliceConfig.RoadObjects = {
  types = {}
}

-- Camera aerea e estado de UI. O restante do bloco Advanced e server-side.
MZPoliceConfig.Advanced = {
  enabled = true,
  Air = {
    enabled = true,
    capability = 'police.air.support',
    helicopterModels = { polmav = true },
    -- Offset do helicam do qb-policejob (0.0, 0.0, -1.5), reproduzido no polmav.
    cameraOffset = { x = 0.0, y = 0.0, z = -1.5 },
    minimumFov = 10.0,
    maximumFov = 80.0
  }
}
