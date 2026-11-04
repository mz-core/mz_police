-- Catalogo juridico ficticio de RP (MZ-RP-STAGING-2).
-- Nao representa legislacao real. Deve espelhar mz_prison/config.lua em
-- ruleCode, name, legalVersion e sentenceSeconds. Conversao usada: 1 mes = 60s.
-- Referencia: mz_docs/police/P13_PENAL_CODE_AND_PATROL.md.
--
-- Este arquivo e carregado somente no servidor. O cliente recebe os dados
-- necessarios pelos eventos/NUI do MDT, nunca calcula pena ou multa.

MZPoliceConfig = MZPoliceConfig or {}
MZPoliceConfig.Records = MZPoliceConfig.Records or {}

local records = MZPoliceConfig.Records

records.legalRulesEnabled = true
records.legalVersion = 'MZ-RP-STAGING-2'
records.jurisdictions = {
  police = { enabled = true }
}
records.charges = {
      HOMICIDIO_DOLOSO = {
        enabled = true,
        name = 'Homicídio doloso',
        description = 'Art. 121: tirar a vida de outra pessoa de forma intencional.',
        category = 'Contra a vida',
        fineAmount = 50000,
        sentenceSeconds = 7200
      },
      HOMICIDIO_CULPOSO = {
        enabled = true,
        name = 'Homicídio culposo',
        description = 'Art. 121, §3º: morte por imprudência, negligência ou imperícia.',
        category = 'Contra a vida',
        fineAmount = 30000,
        sentenceSeconds = 2400
      },
      LATROCINIO = {
        enabled = true,
        name = 'Latrocínio',
        description = 'Art. 157, §3º: roubo seguido de morte.',
        category = 'Contra a vida e o patrimônio',
        fineAmount = 80000,
        sentenceSeconds = 7200
      },
      LESAO_CORPORAL_GRAVE = {
        enabled = true,
        name = 'Lesão corporal grave',
        description = 'Art. 129: ofensa à integridade física com incapacidade ou perigo de vida.',
        category = 'Contra a pessoa',
        fineAmount = 30000,
        sentenceSeconds = 2400
      },
      TENTATIVA_HOMICIDIO = {
        enabled = true,
        name = 'Tentativa de homicídio',
        description = 'Art. 121 c/c art. 14, II: tentativa de homicídio.',
        category = 'Contra a vida',
        fineAmount = 50000,
        sentenceSeconds = 4800
      },
      ROUBO = {
        enabled = true,
        name = 'Roubo',
        description = 'Art. 157: subtração mediante grave ameaça ou violência.',
        category = 'Contra o patrimônio',
        fineAmount = 50000,
        sentenceSeconds = 3000
      },
      FURTO = {
        enabled = true,
        name = 'Furto',
        description = 'Art. 155: subtração sem violência ou grave ameaça.',
        category = 'Contra o patrimônio',
        fineAmount = 30000,
        sentenceSeconds = 1800
      },
      EXTORSAO = {
        enabled = true,
        name = 'Extorsão',
        description = 'Art. 158: constranger alguém a fazer ou tolerar algo mediante violência ou ameaça.',
        category = 'Contra o patrimônio',
        fineAmount = 40000,
        sentenceSeconds = 2400
      },
      ASSALTO_BANCO_JOALHERIA = {
        enabled = true,
        name = 'Assalto a banco ou joalheria',
        description = 'Assalto a banco ou joalheria com violência ou grave ameaça.',
        category = 'Contra o patrimônio',
        fineAmount = 120000,
        sentenceSeconds = 7200
      },
      ASSALTO_CAIXA_ELETRONICO = {
        enabled = true,
        name = 'Assalto a caixa eletrônico',
        description = 'Arrombamento ou explosão de caixa eletrônico.',
        category = 'Contra o patrimônio',
        fineAmount = 50000,
        sentenceSeconds = 3000
      },
      ASSALTO_LOJA = {
        enabled = true,
        name = 'Assalto a loja',
        description = 'Assalto a loja ou comércio com violência ou grave ameaça.',
        category = 'Contra o patrimônio',
        fineAmount = 50000,
        sentenceSeconds = 3000
      },
      VEICULO_CLONADO = {
        enabled = true,
        name = 'Veículo clonado',
        description = 'Uso de veículo com identificação adulterada ou clonada.',
        category = 'Contra a fé pública',
        fineAmount = 30000,
        sentenceSeconds = 1800
      },
      RECEPTACAO = {
        enabled = true,
        name = 'Receptação',
        description = 'Art. 180: adquirir ou ocultar produto de crime.',
        category = 'Contra o patrimônio',
        fineAmount = 20000,
        sentenceSeconds = 1200
      },
      VANDALISMO = {
        enabled = true,
        name = 'Vandalismo',
        description = 'Dano, depredação ou destruição de bem público ou privado.',
        category = 'Contra o patrimônio público',
        fineAmount = 30000,
        sentenceSeconds = 1800
      },
      PORTE_ARMA_BAIXO_CALIBRE = {
        enabled = true,
        name = 'Porte ilegal de arma de baixo calibre',
        description = 'Porte ou posse ilegal de arma de baixo calibre.',
        category = 'Armas',
        fineAmount = 40000,
        sentenceSeconds = 2400
      },
      PORTE_ARMA_ALTO_CALIBRE = {
        enabled = true,
        name = 'Porte ilegal de arma de alto calibre',
        description = 'Porte ou posse ilegal de arma de alto calibre.',
        category = 'Armas',
        fineAmount = 80000,
        sentenceSeconds = 4800
      },
      TRAFICO_ARMAS = {
        enabled = true,
        name = 'Tráfico de armas',
        description = 'Comércio ou transporte ilegal de armas.',
        category = 'Armas',
        fineAmount = 80000,
        sentenceSeconds = 4800
      },
      TRAFICO_MUNICOES = {
        enabled = true,
        name = 'Tráfico de munições',
        description = 'Comércio ou transporte ilegal de munições.',
        category = 'Armas',
        fineAmount = 80000,
        sentenceSeconds = 4800
      },
      PORTE_ITENS_ARRUMBAMENTO = {
        enabled = true,
        name = 'Porte de itens de arrombamento',
        description = 'Posse de lockpick, masterpick, algemas ou itens de arrombamento sem autorização.',
        category = 'Armas',
        fineAmount = 20000,
        sentenceSeconds = 1200
      },
      TRAFICO_DROGAS = {
        enabled = true,
        name = 'Tráfico de drogas',
        description = 'Produção, distribuição ou venda de drogas ilícitas.',
        category = 'Entorpecentes',
        fineAmount = 80000,
        sentenceSeconds = 4800
      },
      ASSOCIACAO_TRAFICO = {
        enabled = true,
        name = 'Associação ao tráfico',
        description = 'Associação para o tráfico de drogas.',
        category = 'Entorpecentes',
        fineAmount = 80000,
        sentenceSeconds = 4800
      },
      CORRUPCAO_PASSIVA = {
        enabled = true,
        name = 'Corrupção passiva',
        description = 'Art. 317: receber vantagem indevida em razão do cargo.',
        category = 'Administração pública',
        fineAmount = 120000,
        sentenceSeconds = 7200
      },
      CORRUPCAO_ATIVA = {
        enabled = true,
        name = 'Corrupção ativa',
        description = 'Art. 333: oferecer vantagem indevida a servidor público.',
        category = 'Administração pública',
        fineAmount = 120000,
        sentenceSeconds = 7200
      },
      DESACATO = {
        enabled = true,
        name = 'Desacato',
        description = 'Art. 331: desacatar servidor público no exercício da função.',
        category = 'Administração pública',
        fineAmount = 20000,
        sentenceSeconds = 1200
      },
      ABUSO_PODER = {
        enabled = true,
        name = 'Abuso de poder',
        description = 'Uso indevido de autoridade ou poder público.',
        category = 'Administração pública',
        fineAmount = 60000,
        sentenceSeconds = 3600
      },
      FALSIDADE_IDEOLOGICA = {
        enabled = true,
        name = 'Falsidade ideológica',
        description = 'Art. 299: inserir declaração falsa em documento público ou particular.',
        category = 'Fé pública',
        fineAmount = 30000,
        sentenceSeconds = 1800
      },
      SUBORNO = {
        enabled = true,
        name = 'Suborno',
        description = 'Oferecer ou prometer vantagem indevida a autoridade.',
        category = 'Administração pública',
        fineAmount = 40000,
        sentenceSeconds = 2400
      },
      FORMACAO_QUADRILHA = {
        enabled = true,
        name = 'Formação de quadrilha',
        description = 'Associação de três ou mais pessoas para cometer crimes.',
        category = 'Organização criminosa',
        fineAmount = 50000,
        sentenceSeconds = 3000
      },
      ORGANIZACAO_CRIMINOSA = {
        enabled = true,
        name = 'Organização criminosa',
        description = 'Estrutura organizada para prática de crimes graves.',
        category = 'Organização criminosa',
        fineAmount = 80000,
        sentenceSeconds = 4800
      },
      LAVAGEM_DINHEIRO = {
        enabled = true,
        name = 'Lavagem de dinheiro',
        description = 'Ocultar ou dissimular a origem de valores ilícitos.',
        category = 'Organização criminosa',
        fineAmount = 80000,
        sentenceSeconds = 4800
      },
      TENTATIVA_FUGA = {
        enabled = true,
        name = 'Tentativa de fuga',
        description = 'Tentativa de evadir-se de custódia legal.',
        category = 'Processual',
        fineAmount = 30000,
        sentenceSeconds = 1800
      },
      RESISTENCIA_PRISAO = {
        enabled = true,
        name = 'Resistência à prisão',
        description = 'Resistência à prisão ou à ação policial.',
        category = 'Processual',
        fineAmount = 20000,
        sentenceSeconds = 1200
      },
      DESOBEDIENCIA = {
        enabled = true,
        name = 'Desobediência',
        description = 'Descumprimento de ordem legal de autoridade.',
        category = 'Processual',
        fineAmount = 10000,
        sentenceSeconds = 600
      },
      PERJURIO = {
        enabled = true,
        name = 'Perjúrio',
        description = 'Falsa declaração em processo ou investigação.',
        category = 'Processual',
        fineAmount = 30000,
        sentenceSeconds = 1800
      },
      PLANTAR_PROVAS = {
        enabled = true,
        name = 'Plantar provas',
        description = 'Manipular ou inserir provas falsas para incriminar alguém.',
        category = 'Processual',
        fineAmount = 50000,
        sentenceSeconds = 3000
      },
      DIRECAO_PERIGOSA = {
        enabled = true,
        name = 'Direção perigosa',
        description = 'Condução em velocidade incompatível ou com risco à segurança.',
        category = 'Trânsito',
        fineAmount = 20000,
        sentenceSeconds = 1200
      },
      CORRIDA_ILEGAL = {
        enabled = true,
        name = 'Corrida ilegal',
        description = 'Disputa de velocidade não autorizada em via pública.',
        category = 'Trânsito',
        fineAmount = 40000,
        sentenceSeconds = 2400
      },
      PORTE_MASCARA = {
        enabled = true,
        name = 'Porte de máscara',
        description = 'Uso de máscara ou disfarce para ocultar identidade em contexto criminoso.',
        category = 'Ordem pública',
        fineAmount = 10000,
        sentenceSeconds = 600
      },
      DINHEIRO_SUJO = {
        enabled = true,
        name = 'Dinheiro sujo',
        description = 'Posse ou transporte de valores incompatíveis com a atividade declarada.',
        category = 'Ordem pública',
        fineAmount = 30000,
        sentenceSeconds = 1800
      },
      COLETE_BALISTICO_IRREGULAR = {
        enabled = true,
        name = 'Colete balístico irregular',
        description = 'Posse de colete balístico acima do limite autorizado.',
        category = 'Armas',
        fineAmount = 30000,
        sentenceSeconds = 1800
      },
}
records.citations = {
      CITACAO_EXCESSO_VELOCIDADE = {
        enabled = true,
        name = 'Excesso de velocidade',
        description = 'Excesso de velocidade em via pública.',
        fineAmount = 12000
      },
      CITACAO_DIRECAO_PERIGOSA = {
        enabled = true,
        name = 'Direção perigosa',
        description = 'Condução perigosa sem dano ou lesão.',
        fineAmount = 15000
      },
      CITACAO_EMBRIAGUEZ = {
        enabled = true,
        name = 'Embriaguez ao volante',
        description = 'Condução sob influência de álcool ou entorpecente.',
        fineAmount = 30000
      },
      CITACAO_CORRIDA_ILEGAL = {
        enabled = true,
        name = 'Corrida ilegal',
        description = 'Participação em corrida ilegal.',
        fineAmount = 30000
      },
      CITACAO_ESTACIONAMENTO_IRREGULAR = {
        enabled = true,
        name = 'Estacionamento irregular',
        description = 'Estacionamento em local proibido.',
        fineAmount = 5000
      },
      CITACAO_POLUICAO_SONORA = {
        enabled = true,
        name = 'Poluição sonora',
        description = 'Perturbação do sossego por som alto.',
        fineAmount = 8000
      },
      CITACAO_PERTURBACAO_ORDEM = {
        enabled = true,
        name = 'Perturbação da ordem',
        description = 'Perturbação da ordem pública.',
        fineAmount = 8000
      },
      CITACAO_POSSE_DROGAS_USO = {
        enabled = true,
        name = 'Posse de droga para uso',
        description = 'Posse de entorpecente para uso próprio.',
        fineAmount = 10000
      },
      CITACAO_PORTE_MASCARA = {
        enabled = true,
        name = 'Porte de máscara',
        description = 'Uso de máscara em situação suspeita.',
        fineAmount = 10000
      },
      CITACAO_DANO_PATRIMONIO = {
        enabled = true,
        name = 'Dano ao patrimônio',
        description = 'Dano ou depredação de patrimônio.',
        fineAmount = 25000
      },
      CITACAO_TRANSPORTE_IRREGULAR = {
        enabled = true,
        name = 'Transporte irregular',
        description = 'Transporte irregular de passageiros ou cargas.',
        fineAmount = 15000
      },
}
-- Mandados habilitados sem regras: qualquer criacao falha em
-- legal_rule_not_configured ate warrants.rules ser aprovado.
records.warrants = { enabled = true, rules = {} }
