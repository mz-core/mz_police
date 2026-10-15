(() => {
  'use strict';

  const preview = typeof window.GetParentResourceName !== 'function';
  const resourceName = preview ? 'mz_police' : window.GetParentResourceName();
  const app = document.getElementById('app');
  const content = document.getElementById('content');
  const navigation = document.getElementById('navigation');
  const title = document.getElementById('section-title');
  const kicker = document.getElementById('section-kicker');
  const loadingBar = document.getElementById('loading-bar');
  const previewBadge = document.getElementById('preview-badge');
  const toastRegion = document.getElementById('toast-region');

  const sections = [
    ['dashboard', 'Dashboard', 'layout-dashboard', 'VISÃO OPERACIONAL'],
    ['citizens', 'Cidadãos', 'search', 'CONSULTA AUTORIZADA'],
    ['profile', 'Ficha', 'contact-round', 'FICHA DO CIDADÃO'],
    ['cases', 'Ocorrências', 'folders', 'CASOS E OCORRÊNCIAS'],
    ['charges', 'Acusações', 'scale', 'CÓDIGO PENAL'],
    ['citations', 'Multas', 'receipt-text', 'LANÇAMENTOS FINANCEIROS'],
    ['warrants', 'Mandados', 'file-warning', 'REVISÃO SEPARADA'],
    ['evidence', 'Evidências', 'scan-barcode', 'CADEIA DE CUSTÓDIA'],
    ['history', 'Histórico', 'history', 'TRILHA DE AÇÕES'],
  ];

  const state = {
    open: false,
    active: 'dashboard',
    cases: [],
    selectedCase: null,
    citizenSearch: null,
    selectedCitizen: null,
    evidence: null,
    loading: new Set(),
    pending: new Map(),
    sequence: 0,
  };

  const codeLabels = {
    capability_denied: 'Capability insuficiente para esta operação.',
    duty_required: 'Entre em serviço para usar o MDT.',
    legal_rules_disabled: 'O catálogo jurídico está desativado.',
    records_unavailable: 'O backend de registros não está pronto.',
    evidence_container_not_configured: 'O contêiner de evidências não está configurado.',
    organization_unavailable: 'O serviço de organizações está indisponível.',
    rate_limited: 'Muitas solicitações. Aguarde e tente novamente.',
    request_timeout: 'O servidor não respondeu dentro do limite.',
    revision_conflict: 'O caso foi alterado por outro operador. Atualize antes de salvar.',
  };

  const esc = (value) => String(value ?? '')
    .replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;').replaceAll("'", '&#039;');
  const value = (object, ...keys) => keys.map((key) => object?.[key]).find((item) => item !== undefined && item !== null);
  const requestId = (prefix) => `${prefix}_${Date.now().toString(36)}_${(++state.sequence).toString(36)}`;
  const nameOf = (citizen) => [value(citizen, 'firstname', 'firstName'), value(citizen, 'lastname', 'lastName')].filter(Boolean).join(' ') || 'Nome não disponível';
  const statusClass = (status) => String(status || '').toLowerCase().replace(/[^a-z]/g, '');
  const formatDate = (date) => {
    const parsed = date ? new Date(date) : null;
    return parsed && !Number.isNaN(parsed.getTime())
      ? new Intl.DateTimeFormat('pt-BR', { dateStyle: 'short', timeStyle: 'short' }).format(parsed)
      : 'Não informado';
  };
  const money = (amount) => new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(Number(amount || 0));

  function icons() {
    if (window.lucide) window.lucide.createIcons({ attrs: { 'stroke-width': 1.7, 'aria-hidden': 'true' } });
  }

  function toast(message, kind = 'info') {
    const item = document.createElement('div');
    item.className = `toast ${kind === 'error' ? 'error' : ''}`;
    item.textContent = message;
    toastRegion.appendChild(item);
    window.setTimeout(() => item.remove(), 4200);
  }

  function setLoading(action, enabled) {
    if (enabled) state.loading.add(action); else state.loading.delete(action);
    loadingBar.hidden = state.loading.size === 0;
  }

  async function post(endpoint, body) {
    const response = await fetch(`https://${resourceName}/${endpoint}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json; charset=UTF-8' }, body: JSON.stringify(body || {}),
    });
    return response.json();
  }

  function request(action, payload = {}) {
    if (preview) return Promise.resolve({ ok: false, code: 'preview_only' });
    const id = requestId(action);
    setLoading(action, true);
    return new Promise(async (resolve) => {
      const timer = window.setTimeout(() => {
        state.pending.delete(id);
        setLoading(action, false);
        resolve({ ok: false, code: 'request_timeout' });
      }, 16000);
      state.pending.set(id, { action, resolve, timer });
      try {
        const accepted = await post('request', { action, requestId: id, payload });
        if (accepted.accepted !== true) {
          window.clearTimeout(timer);
          state.pending.delete(id);
          setLoading(action, false);
          resolve({ ok: false, code: accepted.code || 'request_rejected' });
        }
      } catch (_) {
        window.clearTimeout(timer);
        state.pending.delete(id);
        setLoading(action, false);
        resolve({ ok: false, code: 'nui_transport_failed' });
      }
    });
  }

  function unavailable(titleText, message) {
    return `<div class="empty"><div><i data-lucide="shield-alert"></i><strong>${esc(titleText)}</strong><p>${esc(message)}</p></div></div>`;
  }

  function empty(titleText, message, icon = 'inbox') {
    return `<div class="empty"><div><i data-lucide="${icon}"></i><strong>${esc(titleText)}</strong><p>${esc(message)}</p></div></div>`;
  }

  function caseRows(items = []) {
    if (!items.length) return empty('Nenhum caso retornado', 'A consulta autorizada não retornou ocorrências para esta página.', 'folder-open');
    return `<div class="data-list">${items.map((item) => `
      <button class="data-row" type="button" data-case-id="${esc(value(item, 'public_id', 'publicId'))}">
        <span><strong>${esc(item.title)}</strong><small>${esc(value(item, 'public_id', 'publicId'))}</small></span>
        <span>${esc(value(item, 'case_kind', 'caseKind') || 'case')}</span>
        <span class="status ${statusClass(item.status)}">${esc(item.status || 'unknown')}</span>
      </button>`).join('')}</div>`;
  }

  function renderDashboard() {
    const selected = state.selectedCitizen;
    return `<div class="stack">
      ${preview ? '<div class="notice">Preview visual isolado. Nenhum registro real foi carregado.</div>' : ''}
      <div class="split">
        <div class="panel">
          <div class="panel-header"><div><h2>Casos recentes</h2><p>Resultados da página atual do contrato P6.</p></div><button class="button" data-go="cases"><i data-lucide="arrow-right"></i>Abrir casos</button></div>
          ${caseRows(state.cases)}
        </div>
        <div class="stack">
          <div class="metrics">
            <div class="metric accent"><span>CASOS NESTA PÁGINA</span><strong>${state.cases.length}</strong></div>
            <div class="metric"><span>CIDADÃO EM CONTEXTO</span><strong>${selected ? '1' : '0'}</strong></div>
          </div>
          <div class="panel">
            <div class="panel-header"><div><h2>Escopo dos dados</h2><p>Sem indicadores agregados no backend atual.</p></div></div>
            <div class="panel-body"><div class="notice">Os números acima representam somente dados já retornados nesta sessão do MDT. Não são métricas globais.</div></div>
          </div>
        </div>
      </div>
    </div>`;
  }

  function renderCitizens() {
    const result = state.citizenSearch;
    const items = result?.items || [];
    return `<div class="stack">
      <div class="panel">
        <div class="panel-header"><div><h2>Consulta de cidadãos</h2><p>Nome ou identificador, mínimo de dois caracteres.</p></div></div>
        <form id="citizen-search-form" class="panel-body toolbar">
          <div class="field"><label for="citizen-query">Termo de busca</label><input id="citizen-query" name="query" maxlength="64" autocomplete="off" placeholder="Nome ou citizen ID…" required></div>
          <button class="button primary" type="submit"><i data-lucide="search"></i>Consultar</button>
        </form>
      </div>
      <div class="panel">
        <div class="panel-header"><div><h2>Resultados</h2><p>${result ? `${Number(result.total || 0)} registro(s) encontrado(s)` : 'Aguardando consulta autorizada.'}</p></div></div>
        ${items.length ? `<div class="data-list">${items.map((item) => `
          <button class="data-row" type="button" data-citizen-id="${esc(item.citizenid)}">
            <span><strong>${esc(nameOf(item))}</strong><small>${esc(item.citizenid)}</small></span>
            <span>${esc(item.characterStatus || 'active')}</span><span class="status open">ABRIR FICHA</span>
          </button>`).join('')}</div>` : empty('Nenhum resultado carregado', 'Faça uma consulta para abrir uma ficha policial.', 'search')}
      </div>
    </div>`;
  }

  function selectedCitizenRequired(sectionName) {
    if (state.selectedCitizen) return null;
    return unavailable(`${sectionName} indisponível`, 'Selecione primeiro um cidadão na tela de consulta.');
  }

  function renderProfile() {
    const missing = selectedCitizenRequired('Ficha');
    if (missing) return missing;
    const citizen = state.selectedCitizen.citizen || {};
    const police = state.selectedCitizen.police || {};
    const record = police.record || {};
    return `<div class="stack">
      <div class="panel"><div class="panel-body profile-head">
        <div><h2 class="profile-name">${esc(nameOf(citizen))}</h2><div class="profile-id">${esc(citizen.citizenid)}</div></div>
        <span class="status open">${esc(citizen.characterStatus || 'active')}</span>
      </div></div>
      <div class="details-grid">
        <div class="detail"><span>Telefone</span><strong>${esc(citizen.phone || 'Não informado')}</strong></div>
        <div class="detail"><span>ID do personagem</span><strong>${esc(citizen.id || 'Não informado')}</strong></div>
        <div class="detail"><span>Revisão da ficha</span><strong>${esc(value(record, 'revision') || 0)}</strong></div>
      </div>
      <div class="panel">
        <div class="panel-header"><div><h2>Anotações policiais</h2><p>Isoladas por organização e auditadas no servidor.</p></div></div>
        <form id="record-form" class="panel-body"><div class="field"><label for="record-notes">Anotações</label><textarea id="record-notes" name="notes" maxlength="4000" autocomplete="off" placeholder="Nenhuma anotação registrada…">${esc(record.notes || '')}</textarea></div><div class="form-actions"><button class="button primary" type="submit"><i data-lucide="save"></i>Salvar ficha</button></div></form>
      </div>
    </div>`;
  }

  function renderCaseEditor() {
    const current = state.selectedCase;
    if (!current) return `<div class="panel">
      <div class="panel-header"><div><h2>Novo registro</h2><p>Criação autoritativa com capability de escrita.</p></div></div>
      <form id="case-create-form" class="panel-body">
        <div class="form-grid">
          <div class="field"><label for="case-kind">Tipo</label><select id="case-kind" name="kind" autocomplete="off"><option value="occurrence">Ocorrência</option><option value="investigation">Investigação</option><option value="case">Caso</option></select></div>
          <div class="field"><label for="case-title">Título</label><input id="case-title" name="title" maxlength="160" autocomplete="off" required></div>
          <div class="field wide"><label for="case-summary">Resumo</label><textarea id="case-summary" name="summary" maxlength="8000" autocomplete="off"></textarea></div>
        </div>
        <div class="form-actions"><button class="button primary" type="submit"><i data-lucide="folder-plus"></i>Criar registro</button></div>
      </form>
    </div>`;

    const caseId = value(current, 'public_id', 'publicId');
    const people = current.people || [];
    return `<div class="stack">
      <div class="panel">
        <div class="panel-header"><div><h2>Detalhes do caso</h2><p>${esc(caseId)} | revisão ${esc(current.revision)}</p></div><button id="new-case" class="button" type="button"><i data-lucide="plus"></i>Novo</button></div>
        <form id="case-update-form" class="panel-body">
          <div class="form-grid">
            <div class="field"><label for="case-edit-status">Estado</label><select id="case-edit-status" name="status" autocomplete="off"><option value="open" ${current.status === 'open' ? 'selected' : ''}>Aberto</option><option value="closed" ${current.status === 'closed' ? 'selected' : ''}>Fechado</option><option value="archived" ${current.status === 'archived' ? 'selected' : ''}>Arquivado</option></select></div>
            <div class="field"><label for="case-edit-title">Título</label><input id="case-edit-title" name="title" maxlength="160" autocomplete="off" value="${esc(current.title)}" required></div>
            <div class="field wide"><label for="case-edit-summary">Resumo</label><textarea id="case-edit-summary" name="summary" maxlength="8000" autocomplete="off">${esc(current.summary || '')}</textarea></div>
          </div>
          <div class="form-actions"><button class="button primary" type="submit"><i data-lucide="save"></i>Salvar caso</button></div>
        </form>
      </div>
      <div class="panel">
        <div class="panel-header"><div><h2>Pessoas vinculadas</h2><p>O servidor valida cidadão e função.</p></div></div>
        <form id="case-person-form" class="panel-body toolbar">
          <div class="field"><label for="case-person-id">Citizen ID</label><input id="case-person-id" name="citizenid" maxlength="64" autocomplete="off" value="${esc(state.selectedCitizen?.citizen?.citizenid || '')}" required></div>
          <div class="field"><label for="case-person-role">Função</label><select id="case-person-role" name="role" autocomplete="off"><option value="subject">Envolvido</option><option value="victim">Vítima</option><option value="witness">Testemunha</option><option value="related">Relacionado</option></select></div>
          <button class="button" type="submit"><i data-lucide="user-plus"></i>Vincular</button>
        </form>
        ${people.length ? `<div class="data-list">${people.map((person) => `<div class="data-row"><span><strong>${esc(person.citizenid)}</strong><small>${esc(person.role)}</small></span><span>${esc(formatDate(value(person, 'updated_at', 'updatedAt')))}</span><span class="status">VINCULADO</span></div>`).join('')}</div>` : empty('Sem pessoas vinculadas', 'Nenhum cidadão foi associado ao caso.', 'users')}
      </div>
    </div>`;
  }

  function renderCases() {
    return `<div class="split">
      <div class="panel">
        <div class="panel-header"><div><h2>Casos e ocorrências</h2><p>Listagem isolada pela organização ativa.</p></div><button id="reload-cases" class="button" type="button"><i data-lucide="refresh-cw"></i>Atualizar</button></div>
        ${caseRows(state.cases)}
      </div>
      ${renderCaseEditor()}
    </div>`;
  }

  function renderCharges() {
    const current = state.selectedCase;
    if (!current) return unavailable('Acusações indisponíveis', 'Abra um caso para visualizar acusações persistidas.');
    const charges = current.charges || [];
    return `<div class="stack"><div class="notice">Inclusão desativada na interface: o P6 não expõe um catálogo jurídico aprovado para seleção. Nenhum código ou pena será inventado.</div><div class="panel"><div class="panel-header"><div><h2>Acusações do caso</h2><p>${esc(value(current, 'public_id', 'publicId'))}</p></div></div>${charges.length ? `<div class="data-list">${charges.map((item) => `<div class="data-row"><span><strong>${esc(value(item, 'rule_name', 'ruleName'))}</strong><small>${esc(value(item, 'public_id', 'publicId'))}</small></span><span>${esc(value(item, 'rule_code', 'ruleCode'))}</span><span class="status">${esc(value(item, 'legal_version', 'legalVersion'))}</span></div>`).join('')}</div>` : empty('Sem acusações', 'O caso não possui acusações persistidas.', 'scale')}</div></div>`;
  }

  function renderCitizenCollection(key, label, icon, row) {
    const missing = selectedCitizenRequired(label);
    if (missing) return missing;
    const collection = state.selectedCitizen.police?.[key] || [];
    return `<div class="stack"><div class="notice">Criação indisponível sem catálogo jurídico aprovado e exposto pelo backend. A interface mostra somente dados persistidos.</div><div class="panel"><div class="panel-header"><div><h2>${esc(label)}</h2><p>Contexto do cidadão selecionado.</p></div></div>${collection.length ? `<div class="data-list">${collection.map(row).join('')}</div>` : empty(`Sem ${label.toLowerCase()}`, 'Nenhum registro foi retornado para este cidadão.', icon)}</div></div>`;
  }

  function renderCitations() {
    return renderCitizenCollection('citations', 'Multas', 'receipt-text', (item) => `<div class="data-row"><span><strong>${esc(value(item, 'rule_name', 'ruleName'))}</strong><small>${esc(value(item, 'public_id', 'publicId'))}</small></span><span>${money(item.amount)}</span><span class="status ${statusClass(item.status)}">${esc(item.status)}</span></div>`);
  }

  function renderWarrants() {
    return renderCitizenCollection('warrants', 'Mandados', 'file-warning', (item) => `<div class="data-row"><span><strong>${esc(value(item, 'rule_name', 'ruleName'))}</strong><small>${esc(value(item, 'public_id', 'publicId'))}</small></span><span>${esc(value(item, 'case_public_id', 'casePublicId'))}</span><span class="status ${statusClass(item.status)}">${esc(item.status)}</span></div>`);
  }

  function renderEvidence() {
    const evidence = state.evidence;
    const items = evidence?.items || [];
    return `<div class="stack"><div class="notice">A associação entre evidência e caso continua desativada no backend. Esta tela não simula esse vínculo.</div><div class="panel"><div class="panel-header"><div><h2>Intake de evidências</h2><p>Leitura server-side do contêiner configurado.</p></div><button id="load-evidence" class="button" type="button"><i data-lucide="scan-barcode"></i>Consultar intake</button></div>${items.length ? `<div class="data-list">${items.map((item) => `<div class="data-row"><span><strong>${esc(item.label || item.name || 'Item de evidência')}</strong><small>${esc(value(item, 'instanceUid', 'instance_uid'))}</small></span><span>${esc(value(item, 'evidenceId', 'evidence_id') || 'Identificado')}</span><span class="status">REV ${esc(value(item, 'revision') || 1)}</span></div>`).join('')}</div>` : empty('Nenhuma evidência carregada', 'Consulte o intake. A operação exige capability própria.', 'scan-barcode')}</div></div>`;
  }

  function renderHistory() {
    const missing = selectedCitizenRequired('Histórico');
    if (missing) return missing;
    const items = state.selectedCitizen.police?.history || [];
    return `<div class="panel"><div class="panel-header"><div><h2>Histórico de ações</h2><p>Trilha durável do cidadão no domínio policial.</p></div></div>${items.length ? `<div class="data-list">${items.map((item) => `<div class="data-row"><span><strong>${esc(item.action)}</strong><small>${esc(value(item, 'entity_id', 'entityId'))}</small></span><span>${esc(value(item, 'actor_citizenid', 'actorCitizenid'))}</span><span>${esc(formatDate(value(item, 'created_at', 'createdAt')))}</span></div>`).join('')}</div>` : empty('Sem histórico', 'Nenhuma ação policial foi retornada para este cidadão.', 'history')}</div>`;
  }

  const renders = {
    dashboard: renderDashboard, citizens: renderCitizens, profile: renderProfile, cases: renderCases,
    charges: renderCharges, citations: renderCitations, warrants: renderWarrants,
    evidence: renderEvidence, history: renderHistory,
  };

  function renderNavigation() {
    navigation.innerHTML = sections.map(([id, label, icon]) => `<button class="nav-button ${state.active === id ? 'is-active' : ''}" type="button" data-section="${id}" aria-current="${state.active === id ? 'page' : 'false'}"><i data-lucide="${icon}"></i><span>${label}</span></button>`).join('');
  }

  function render() {
    const meta = sections.find(([id]) => id === state.active) || sections[0];
    title.textContent = meta[1];
    kicker.textContent = meta[3];
    renderNavigation();
    content.innerHTML = renders[state.active]();
    bindContent();
    icons();
  }

  function messageFor(response) {
    return codeLabels[response?.code] || `Operação recusada: ${response?.code || 'erro desconhecido'}.`;
  }

  async function loadCases() {
    const response = await request('listCases', { page: 1, pageSize: 25 });
    if (response.ok) state.cases = response.items || [];
    else toast(messageFor(response), 'error');
    render();
  }

  async function loadCase(caseId) {
    const response = await request('getCase', { caseId });
    if (!response.ok) { toast(messageFor(response), 'error'); return; }
    state.selectedCase = response.case;
    state.active = 'cases';
    render();
  }

  async function loadCitizen(citizenid) {
    const response = await request('getCitizen', { citizenid });
    if (!response.ok) { toast(messageFor(response), 'error'); return; }
    state.selectedCitizen = response;
    state.active = 'profile';
    render();
  }

  function bindContent() {
    content.querySelectorAll('[data-go]').forEach((button) => button.addEventListener('click', () => { state.active = button.dataset.go; render(); }));
    content.querySelectorAll('[data-case-id]').forEach((button) => button.addEventListener('click', () => loadCase(button.dataset.caseId)));
    content.querySelectorAll('[data-citizen-id]').forEach((button) => button.addEventListener('click', () => loadCitizen(button.dataset.citizenId)));

    document.getElementById('reload-cases')?.addEventListener('click', loadCases);
    document.getElementById('new-case')?.addEventListener('click', () => { state.selectedCase = null; render(); });
    document.getElementById('load-evidence')?.addEventListener('click', async () => {
      const response = await request('evidenceList', { containerId: 'intake' });
      if (response.ok) state.evidence = response; else toast(messageFor(response), 'error');
      render();
    });

    document.getElementById('citizen-search-form')?.addEventListener('submit', async (event) => {
      event.preventDefault();
      const query = document.getElementById('citizen-query').value.trim();
      if (query.length < 2) { toast('Informe pelo menos dois caracteres.', 'error'); return; }
      const response = await request('searchCitizens', { query, page: 1, pageSize: 25 });
      if (response.ok) state.citizenSearch = response.result; else toast(messageFor(response), 'error');
      render();
    });

    document.getElementById('record-form')?.addEventListener('submit', async (event) => {
      event.preventDefault();
      const response = await request('upsertRecord', {
        citizenid: state.selectedCitizen.citizen.citizenid,
        notes: document.getElementById('record-notes').value,
        requestId: requestId('record'),
      });
      if (!response.ok) { toast(messageFor(response), 'error'); return; }
      state.selectedCitizen.police.record = response.record;
      toast('Ficha atualizada.');
      render();
    });

    document.getElementById('case-create-form')?.addEventListener('submit', async (event) => {
      event.preventDefault();
      const response = await request('createCase', {
        kind: document.getElementById('case-kind').value,
        title: document.getElementById('case-title').value,
        summary: document.getElementById('case-summary').value,
        requestId: requestId('case'),
      });
      if (!response.ok) { toast(messageFor(response), 'error'); return; }
      state.selectedCase = response.case;
      toast('Registro criado.');
      await loadCases();
    });

    document.getElementById('case-update-form')?.addEventListener('submit', async (event) => {
      event.preventDefault();
      const response = await request('updateCase', {
        caseId: value(state.selectedCase, 'public_id', 'publicId'),
        title: document.getElementById('case-edit-title').value,
        summary: document.getElementById('case-edit-summary').value,
        status: document.getElementById('case-edit-status').value,
        expectedRevision: Number(state.selectedCase.revision),
        requestId: requestId('case_update'),
      });
      if (!response.ok) { toast(messageFor(response), 'error'); return; }
      state.selectedCase = response.case;
      toast('Caso atualizado.');
      await loadCases();
    });

    document.getElementById('case-person-form')?.addEventListener('submit', async (event) => {
      event.preventDefault();
      const response = await request('addCasePerson', {
        caseId: value(state.selectedCase, 'public_id', 'publicId'),
        citizenid: document.getElementById('case-person-id').value,
        role: document.getElementById('case-person-role').value,
        requestId: requestId('case_person'),
      });
      if (!response.ok) { toast(messageFor(response), 'error'); return; }
      state.selectedCase = response.case;
      toast('Pessoa vinculada ao caso.');
      render();
    });
  }

  function open(bootstrap = {}) {
    state.open = true;
    state.active = 'dashboard';
    state.cases = bootstrap.items || [];
    app.classList.add('is-open');
    app.setAttribute('aria-hidden', 'false');
    previewBadge.hidden = !preview;
    render();
  }

  function close() {
    state.open = false;
    app.classList.remove('is-open');
    app.setAttribute('aria-hidden', 'true');
  }

  async function requestClose() {
    if (preview) { close(); return; }
    try { await post('close', {}); } finally { close(); }
  }

  navigation.addEventListener('click', (event) => {
    const button = event.target.closest('[data-section]');
    if (!button) return;
    state.active = button.dataset.section;
    render();
  });
  document.getElementById('close-button').addEventListener('click', requestClose);
  document.getElementById('refresh-button').addEventListener('click', () => state.active === 'cases' || state.active === 'dashboard' ? loadCases() : render());
  document.addEventListener('keydown', (event) => { if (event.key === 'Escape' && state.open) requestClose(); });
  window.addEventListener('message', (event) => {
    const message = event.data || {};
    if (message.type === 'mdt:open') { open(message.bootstrap || {}); return; }
    if (message.type === 'mdt:close') { close(); return; }
    if (message.type !== 'mdt:result') return;
    const pending = state.pending.get(message.requestId);
    if (!pending) return;
    window.clearTimeout(pending.timer);
    state.pending.delete(message.requestId);
    setLoading(pending.action, false);
    pending.resolve(message.response || { ok: false, code: 'invalid_response' });
  });

  if (preview) open({ items: [] });
})();
