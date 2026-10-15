local function read(path)
  local file = assert(io.open(path, 'rb'))
  local value = file:read('*a')
  file:close()
  return value
end
local function expect(condition, message) if not condition then error(message, 2) end end

local manifest = read('fxmanifest.lua')
local config = read('server/config.lua')
local prepare = read('server/records_prepare.lua')
local repository = read('server/records_repository.lua')
local records = read('server/records.lua')
local bridge = read('server/bridge.lua')

expect(manifest:find("'oxmysql'", 1, true), 'dependencia oxmysql ausente')
expect(manifest:find("'mz_economy'", 1, true), 'dependencia mz_economy ausente')
expect(config:find('legalRulesEnabled = false', 1, true), 'regras legais nao estao fail-closed')
expect(config:find('citations = {}', 1, true), 'catalogo de multas inventado')
expect(prepare:find('mz_police_cases', 1, true) and prepare:find('mz_police_citations', 1, true)
  and prepare:find('mz_police_warrants', 1, true), 'schema P6 incompleto')
expect(prepare:find('mz_police_case_evidence', 1, true), 'schema de vinculo investigativo ausente')
expect(repository:find('MySQL.transaction.await', 1, true), 'mutacoes policiais nao usam transacao')
expect(records:find("MZPoliceConfig.Records.citationCapability", 1, true), 'capability de multa ausente')
expect(records:find("MZPoliceConfig.Records.warrantApproveCapability", 1, true), 'capability de aprovacao ausente')
expect(bridge:find("'SettlePlayerOrganizationCharge'", 1, true), 'liquidacao canonica nao utilizada')
expect(not records:find('RemoveMoney', 1, true), 'mz_police escreve saldo diretamente')

print('mz_police P6 static harness: PASS cases=11')
