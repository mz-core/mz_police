-- Configuracao server-side: autoridade, permissoes, persistencia e operacao.
-- O catalogo penal fica em config/penal_code.lua.

MZPoliceConfig = MZPoliceConfig or {}

-- O owner mz_org continua responsavel por membership, grade, duty e capabilities.
MZPoliceConfig.AuthorizedOrganizations = {
  police = true
}

MZPoliceConfig.RejectionLogCooldownSeconds = 30

MZPoliceConfig.Custody = {
  capability = 'police.custody',
  maximumDistance = MZPoliceConfig.Interactions.targetDistance,
  vehicleMaximumDistance = 5.0,
  vehicleConfirmationMs = 3000,
  cleanupIntervalMs = 1000,
  rateLimit = { maximum = 8, windowMs = 5000 },
  requestRetentionMs = 120000
}

MZPoliceConfig.Search.grantTtlSeconds = 30
MZPoliceConfig.Search.sessionRetentionSeconds = 45
MZPoliceConfig.Search.rateLimit = { maximum = 8, windowMs = 5000 }

MZPoliceConfig.Armory = {
  capability = 'armory.basic',
  maximumDistance = 2.5,
  requestRetentionMs = 120000,
  rateLimit = { maximum = 6, windowMs = 5000 },
  catalog = {}
}

MZPoliceConfig.Enforcement = {
  scanDistance = 12.0,
  scanTtlSeconds = 30,
  rateLimit = { maximum = 8, windowMs = 5000 },
  requestRetentionMs = 120000,
  flags = {},
  impoundReasons = {}
}

MZPoliceConfig.RoadObjects.capability = 'police.road.tools'
MZPoliceConfig.RoadObjects.placementDistance = 2.0
MZPoliceConfig.RoadObjects.removalDistance = 8.0
MZPoliceConfig.RoadObjects.maximumPerOfficer = 6
MZPoliceConfig.RoadObjects.maximumGlobal = 60

MZPoliceConfig.Evidence = {
  listCapability = 'police.evidence.collect',
  manageCapability = 'police.evidence.manage',
  requestRetentionMs = 120000,
  rateLimit = { maximum = 8, windowMs = 5000 },
  occurrenceAssociationEnabled = true,
  containers = {
    intake = { label = 'Intake', enabled = true }
  }
}

-- O catalogo juridico e carregado em config/penal_code.lua e complementa esta
-- mesma tabela Records, preservando MZPoliceConfig.Records.charges/citations.
MZPoliceConfig.Records = {
  readCapability = 'mdt.open',
  writeCapability = 'police.records.write',
  citationCapability = 'police.citation.issue',
  warrantCreateCapability = 'police.warrant.create',
  warrantApproveCapability = 'police.warrant.approve',
  requestRetentionMs = 120000,
  rateLimit = { maximum = 12, windowMs = 5000 },
  pageSize = 25,
  maximumPageSize = 50
}

-- Integracao prisional preparada para staging: o lado policial pode encaminhar
-- a sentenca. O mz_prison continua owner e fail-closed.
MZPoliceConfig.Prison = {
  enabled = true,
  sentenceCapability = 'police.arrest.request',
  reviewCapability = 'reports.approve',
  readCapability = 'mdt.open',
  maximumDistance = 3.0,
  rateLimit = { maximum = 6, windowMs = 5000 },

  -- Staging: processamento no recebimento de Bolingbroke. Confirme o ponto e o
  -- routing bucket no MLO antes de producao. O servidor revalida tudo.
  processingEnabled = true,
  processingPoints = {
    bolingbroke_booking = {
      enabled = true,
      coords = { x = 1847.14, y = 2585.90, z = 45.68 },
      radius = 3.0,
      routingBucket = 0
    }
  }
}

-- Backend compartilhado pelo processamento no MDT e pela prisao rapida de
-- patrulha. A NUI nunca envia pena, multa, nome de regra ou versao legal: o
-- servidor revalida o catalogo e calcula tudo.
MZPoliceConfig.Arrest = {
  enabled = true,
  quickEnabled = true,
  writeCapability = 'police.records.write',
  capability = 'police.arrest.request',
  citationCapability = 'police.citation.issue',
  maximumDistance = 3.0,
  maximumCharges = 3,
  multiChargeEnabled = true,
  maximumSentenceSeconds = 7200,
  minimumReportLength = 20,
  maximumNotesLength = 4000,
  rateLimit = { maximum = 8, windowMs = 5000 },
  requestRetentionMs = 120000
}

-- Camera aerea, cameras, rastreamento e pericia. O bloco Air base e compartilhado
-- porque o cliente precisa dos modelos, FOV e offset da camera.
MZPoliceConfig.Advanced.stateTtlSeconds = 12
MZPoliceConfig.Advanced.requestRetentionMs = 120000
MZPoliceConfig.Advanced.rateLimit = { maximum = 20, windowMs = 10000 }
MZPoliceConfig.Advanced.Cameras = {
  enabled = false,
  useCapability = 'police.camera.use',
  viewCapability = 'police.camera.view',
  -- Faltam: dashcamVehicles[modelo] e cctv[id] com label/location/coords/rotation/fov.
  dashcamVehicles = {},
  cctv = {}
}
MZPoliceConfig.Advanced.Tracker = {
  enabled = true,
  useCapability = 'police.tracker.use',
  viewCapability = 'police.tracker.view',
  vehicleModels = {
    police = true,
    police2 = true,
    police3 = true,
    police4 = true,
    police5 = true,
    policeold1 = true,
    policeold2 = true,
    policeb = true,
    policet = true,
    policet3 = true,
    sheriff = true,
    sheriff2 = true,
    fbi = true,
    fbi2 = true,
    pranger = true,
    polgauntlet = true,
    polimpaler5 = true,
    polimpaler6 = true,
    poldominator10 = true,
    polgreenwood = true,
    poldorado = true
  },
  refreshMs = 3000,
  staleAfterMs = 10000
}
MZPoliceConfig.Advanced.Forensics = {
  enabled = false,
  capability = 'police.forensics.request',
  methods = {
    weapon_identity = true
  }
}
