# mz_police

Operacoes policiais server-authoritative do MZ Framework. O resource cobre duty,
target, custodia, algemas, revistas, ocorrencias, MDT, estacoes, arsenal, prisao,
chamados, enforcement, camera aerea e sistemas avancados.

## Estrutura

```text
mz_police/
  config/
    shared.lua        # cliente + servidor (UI, target, restricoes, camera)
    server.lua        # autoridade, permissoes, persistencia, operacao
    penal_code.lua    # catalogo juridico ficticio (server-side)
  client/             # adaptadores de target, radial, NUI e apresentacao
  server/             # owners de dominio e validacao autoritativa
    records/          # schema, repository e service de registros/MDT
    restraints/       # repository e service de algemas/chaves
  locales/            # pt-br, en e en-us (ox_lib)
  sql/                # scripts manuais, nunca executados pelo resource
  web/                # NUI do MDT
  fxmanifest.lua
```

`config/shared.lua` e carregado antes dos scripts de cliente e servidor.
`config/server.lua` e `config/penal_code.lua` sao carregados apenas no servidor.
`MZPoliceConfig` continua sendo a tabela publica consumida pelos modulos.

## Instalacao

1. Garanta `ox_lib`, `oxmysql` e as dependencias MZ listadas no `fxmanifest.lua`.
2. Inicie `mz_core`, `mz_org`, `mz_inventory` e os demais owners antes de `mz_police`.
3. Configure `config/server.lua` (organizacoes, estacoes, armory, prisao e pontos reais).
4. Se for usar persistencia opcional de algemas, aplique manualmente
   `sql/restraints.sql` e habilite `MZPoliceConfig.Restraints.persistence.enabled`.
5. O schema de registros e criado/validado no boot por `server/records/schema.lua`.
   `sql/records_schema_additive.sql` e um fallback manual; nunca e executado sozinho.
6. Reinicie `mz_police` depois de alterar config, manifest ou SQL.

## Contratos

- Eventos, comandos, exports, NUI callbacks e permissoes existentes foram preservados.
- A custodia continua sob `MZPolice.Custody`; registros sob `MZPolice.Records`.
- `mz_org` e o owner de membership, duty e capabilities.
- `mz_inventory` e o owner de itens, UID e serial das algemas.
- `mz_prison` e o owner de sentenca, intake e facility prisional.
- Nenhum SQL e executado automaticamente pela limpeza estrutural.

## Qualidade

A pasta `tests/` foi removida da distribuicao. A suite ativa do tracker V2 fica
em `mz_testkit/tests/mz_police/` e roda com `npm --prefix mz_testkit run
test:mz_police`. Os harnesses antigos continuam recuperaveis no historico Git.
O cache `graphify-out/` foi removido e continua ignorado.

Runtime FiveM, OneSync, MySQL, MLO, CEF e NUI **nao executados** nesta limpeza.
