local function expect(condition, message) if not condition then error(message, 2) end end

local captured = {}
json = { encode = function() return '{}' end }
MySQL = {
  query = { await = function(sql, params)
    captured[#captured + 1] = { sql = sql, params = params }
    return {}
  end },
  single = { await = function() return nil end },
  transaction = { await = function() return true end }
}
MZPolice = {}

dofile('server/records_repository.lua')

MZPolice.RecordsRepository.listCases('police', nil, nil, 25, 0)
local first = captured[1]
expect(#first.params == 3 and first.params[1] == 'police'
  and first.params[2] == 25 and first.params[3] == 0,
  'paginacao sem filtros nao preservou LIMIT/OFFSET')

MZPolice.RecordsRepository.listCases('police', 'incident', 'open', 10, 20)
local filtered = captured[2]
expect(#filtered.params == 5 and filtered.params[1] == 'police'
  and filtered.params[2] == 'incident' and filtered.params[3] == 'open'
  and filtered.params[4] == 10 and filtered.params[5] == 20,
  'paginacao com filtros nao preservou a ordem dos parametros')

print('mz_police P6 repository harness: PASS cases=2')
