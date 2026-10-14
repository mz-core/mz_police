MZPolice = MZPolice or {}

local Prepare = { ready = false, error = nil }
local statements = {
  [[CREATE TABLE IF NOT EXISTS mz_police_records (
    org_code VARCHAR(64) NOT NULL,
    citizenid VARCHAR(64) NOT NULL,
    notes TEXT NOT NULL,
    updated_by_citizenid VARCHAR(64) NOT NULL,
    revision INT UNSIGNED NOT NULL DEFAULT 1,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (org_code, citizenid)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
  [[CREATE TABLE IF NOT EXISTS mz_police_cases (
    public_id VARCHAR(160) NOT NULL PRIMARY KEY,
    org_code VARCHAR(64) NOT NULL,
    case_kind VARCHAR(24) NOT NULL,
    title VARCHAR(160) NOT NULL,
    summary TEXT NOT NULL,
    status VARCHAR(24) NOT NULL DEFAULT 'open',
    created_by_citizenid VARCHAR(64) NOT NULL,
    revision INT UNSIGNED NOT NULL DEFAULT 1,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    KEY idx_mz_police_cases_org_status (org_code, status, updated_at)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
  [[CREATE TABLE IF NOT EXISTS mz_police_case_officers (
    case_public_id VARCHAR(160) NOT NULL,
    citizenid VARCHAR(64) NOT NULL,
    role VARCHAR(32) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (case_public_id, citizenid),
    CONSTRAINT fk_mz_police_case_officers_case FOREIGN KEY (case_public_id)
      REFERENCES mz_police_cases(public_id) ON DELETE CASCADE
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
  [[CREATE TABLE IF NOT EXISTS mz_police_case_people (
    case_public_id VARCHAR(160) NOT NULL,
    citizenid VARCHAR(64) NOT NULL,
    role VARCHAR(32) NOT NULL,
    added_by_citizenid VARCHAR(64) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (case_public_id, citizenid),
    CONSTRAINT fk_mz_police_case_people_case FOREIGN KEY (case_public_id)
      REFERENCES mz_police_cases(public_id) ON DELETE CASCADE
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
  [[CREATE TABLE IF NOT EXISTS mz_police_case_charges (
    public_id VARCHAR(160) NOT NULL PRIMARY KEY,
    case_public_id VARCHAR(160) NOT NULL,
    citizenid VARCHAR(64) NOT NULL,
    rule_code VARCHAR(64) NOT NULL,
    rule_name VARCHAR(160) NOT NULL,
    fine_amount BIGINT UNSIGNED NOT NULL DEFAULT 0,
    sentence_seconds INT UNSIGNED NOT NULL DEFAULT 0,
    legal_version VARCHAR(64) NOT NULL,
    added_by_citizenid VARCHAR(64) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    KEY idx_mz_police_charges_case (case_public_id, citizenid),
    CONSTRAINT fk_mz_police_case_charges_case FOREIGN KEY (case_public_id)
      REFERENCES mz_police_cases(public_id) ON DELETE CASCADE
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
  [[CREATE TABLE IF NOT EXISTS mz_police_citations (
    public_id VARCHAR(160) NOT NULL PRIMARY KEY,
    operation_id VARCHAR(160) NOT NULL,
    org_code VARCHAR(64) NOT NULL,
    case_public_id VARCHAR(160) NULL,
    target_citizenid VARCHAR(64) NOT NULL,
    rule_code VARCHAR(64) NOT NULL,
    rule_name VARCHAR(160) NOT NULL,
    amount BIGINT UNSIGNED NOT NULL,
    legal_version VARCHAR(64) NOT NULL,
    status VARCHAR(24) NOT NULL DEFAULT 'pending',
    economy_receipt_id VARCHAR(128) NULL,
    economy_error VARCHAR(64) NULL,
    issued_by_citizenid VARCHAR(64) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_mz_police_citations_operation (operation_id),
    KEY idx_mz_police_citations_target (org_code, target_citizenid, created_at)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
  [[CREATE TABLE IF NOT EXISTS mz_police_warrants (
    public_id VARCHAR(160) NOT NULL PRIMARY KEY,
    org_code VARCHAR(64) NOT NULL,
    case_public_id VARCHAR(160) NOT NULL,
    target_citizenid VARCHAR(64) NOT NULL,
    rule_code VARCHAR(64) NOT NULL,
    rule_name VARCHAR(160) NOT NULL,
    legal_version VARCHAR(64) NOT NULL,
    status VARCHAR(24) NOT NULL DEFAULT 'pending',
    created_by_citizenid VARCHAR(64) NOT NULL,
    reviewed_by_citizenid VARCHAR(64) NULL,
    reviewed_at TIMESTAMP NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    KEY idx_mz_police_warrants_target (org_code, target_citizenid, status),
    KEY idx_mz_police_warrants_case (case_public_id)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
  [[CREATE TABLE IF NOT EXISTS mz_police_history (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    operation_id VARCHAR(160) NOT NULL,
    org_code VARCHAR(64) NOT NULL,
    entity_type VARCHAR(32) NOT NULL,
    entity_id VARCHAR(160) NOT NULL,
    action VARCHAR(64) NOT NULL,
    request_fingerprint VARCHAR(64) NOT NULL,
    actor_citizenid VARCHAR(64) NOT NULL,
    target_citizenid VARCHAR(64) NULL,
    details_json LONGTEXT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_mz_police_history_operation (operation_id),
    KEY idx_mz_police_history_entity (org_code, entity_type, entity_id, id),
    KEY idx_mz_police_history_target (org_code, target_citizenid, id)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]]
}

local function mysqlReady()
  return MySQL and MySQL.query and type(MySQL.query.await) == 'function'
    and MySQL.single and type(MySQL.single.await) == 'function'
    and MySQL.insert and type(MySQL.insert.await) == 'function'
    and MySQL.update and type(MySQL.update.await) == 'function'
    and MySQL.transaction and type(MySQL.transaction.await) == 'function'
end

function Prepare.run()
  if Prepare.ready then return true end
  if not mysqlReady() then Prepare.error = 'mysql_not_ready'; return false, Prepare.error end
  local ok, errorValue = pcall(function()
    for _, statement in ipairs(statements) do MySQL.query.await(statement) end
  end)
  Prepare.ready = ok == true
  Prepare.error = ok and nil or tostring(errorValue)
  return Prepare.ready, Prepare.error
end

MZPolice.RecordsPrepare = Prepare
