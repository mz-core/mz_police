MZPoliceConfig = {
  -- O owner mz_org continua responsavel por membership, grade, duty e capabilities.
  AuthorizedOrganizations = {
    police = true
  },

  RejectionLogCooldownSeconds = 30,

  Custody = {
    capability = 'police.custody',
    maximumDistance = 2.5,
    vehicleMaximumDistance = 5.0,
    vehicleConfirmationMs = 3000,
    cleanupIntervalMs = 1000,
    rateLimit = { maximum = 8, windowMs = 5000 },
    requestRetentionMs = 120000
  },

  Search = {
    grantTtlSeconds = 30,
    sessionRetentionSeconds = 45,
    defaultEvidenceContainer = 'intake',
    rateLimit = { maximum = 8, windowMs = 5000 }
  },

  -- Vazio por padrao: coordenadas reais devem ser configuradas pelo operador.
  Stations = {},

  Armory = {
    capability = 'armory.basic',
    maximumDistance = 2.5,
    requestRetentionMs = 120000,
    rateLimit = { maximum = 6, windowMs = 5000 },
    catalog = {}
  }
}
