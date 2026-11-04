-- mz_police: espelho manual de fallback do schema de registros.
-- A tabela e criada e validada automaticamente por server/records/schema.lua no boot.
-- Use este arquivo apenas se o usuario MySQL nao puder executar CREATE/REFERENCES.
CREATE TABLE IF NOT EXISTS mz_police_forensic_results (
  public_id VARCHAR(160) NOT NULL PRIMARY KEY,
  operation_id VARCHAR(160) NOT NULL,
  org_code VARCHAR(64) NOT NULL,
  case_public_id VARCHAR(160) NOT NULL,
  evidence_id VARCHAR(160) NOT NULL,
  instance_uid VARCHAR(64) NOT NULL,
  method VARCHAR(64) NOT NULL,
  status VARCHAR(24) NOT NULL,
  result_json LONGTEXT NOT NULL,
  requested_by_citizenid VARCHAR(64) NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_mz_police_forensic_operation (operation_id),
  KEY idx_mz_police_forensic_case (case_public_id, created_at),
  CONSTRAINT fk_mz_police_forensic_case FOREIGN KEY (case_public_id)
    REFERENCES mz_police_cases(public_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
