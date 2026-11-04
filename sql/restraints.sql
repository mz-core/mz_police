-- mz_police: persistencia OPCIONAL de algemas fisicas.
--
-- NAO execute automaticamente. Aplique manualmente apenas em ambiente de
-- desenvolvimento/staging apos aprovacao. O runtime so usa esta tabela quando
-- MZPoliceConfig.Restraints.persistence.enabled = true.
--
-- CREATE-only. Nao altera tabelas existentes.
CREATE TABLE IF NOT EXISTS mz_police_restraints (
  target_citizenid VARCHAR(64) NOT NULL,
  restraint_id VARCHAR(120) NOT NULL,
  target_character_id BIGINT NULL,
  target_session_id BIGINT NULL,
  actor_citizenid VARCHAR(64) NOT NULL,
  actor_character_id BIGINT NULL,
  actor_session_id BIGINT NULL,
  origin VARCHAR(16) NOT NULL,
  status VARCHAR(24) NOT NULL DEFAULT 'active',
  cuff_instance_uid VARCHAR(96) NOT NULL,
  cuff_serial VARCHAR(96) NOT NULL,
  key_instance_uid VARCHAR(96) NULL,
  key_holder_citizenid VARCHAR(64) NULL,
  reason VARCHAR(255) NULL,
  revision INT NOT NULL DEFAULT 1,
  applied_at BIGINT NOT NULL,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (target_citizenid),
  UNIQUE KEY uq_mz_police_restraint_id (restraint_id),
  KEY idx_mz_police_restraint_actor (actor_citizenid),
  KEY idx_mz_police_restraint_key_holder (key_holder_citizenid),
  KEY idx_mz_police_restraint_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
