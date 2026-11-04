(() => {
  'use strict';

  const preview = typeof window.GetParentResourceName !== 'function';
  const resourceName = preview ? 'mz_police' : window.GetParentResourceName();
  const navigationAssetBase = preview
    ? '../../mz_navigation/web'
    : 'https://cfx-nui-mz_navigation/web';
  const app = document.getElementById('app');
  const terminal = app.querySelector('.terminal');
  const content = document.getElementById('content');
  const navigation = document.getElementById('navigation');
  const title = document.getElementById('section-title');
  const kicker = document.getElementById('section-kicker');
  const loadingBar = document.getElementById('loading-bar');
  const previewBadge = document.getElementById('preview-badge');
  const syncStatus = document.getElementById('sync-status');
  const toastRegion = document.getElementById('toast-region');
  const panelRoot = document.getElementById('police-panel-root');
  const trackerMath = window.MZPoliceTrackerMath || null;

  const sections = [
    ['home', 'Início', 'layout-dashboard', 'RESUMO DO TURNO'],
    ['operations', 'Central operacional', 'radio-tower', 'CHAMADOS E UNIDADES'],
    ['consultations', 'Consultas', 'search', 'PESSOAS E REGISTROS'],
    ['vehicles', 'Veículos', 'car-front', 'REGISTRO E ALERTAS'],
    ['cases', 'Casos', 'folders', 'OCORRÊNCIAS E PROCESSAMENTO'],
  ];

  const sectionViews = {
    consultations: [
      ['citizens', 'Pesquisa'], ['profile', 'Ficha'], ['citations', 'Multas'],
      ['warrants', 'Mandados'], ['history', 'Histórico'],
    ],
    cases: [['cases', 'Ocorrências'], ['charges', 'Acusações'], ['evidence', 'Evidências']],
  };

  const state = {
    open: false,
    active: 'home',
    view: 'home',
    cases: [],
    caseFilter: { kind: 'all', period: 'all' },
    selectedCase: null,
    citizenSearch: null,
    selectedCitizen: null,
    vehicleQuery: '',
    selectedVehicle: null,
    evidence: null,
    legalCatalog: null,
    sentence: null,
    dispatch: null,
    trackerSnapshot: null,
    trackerV2: false,
    trackerUnits: new Map(),
    trackerGeneration: -1,
    trackerSeq: -1,
    trackerTickMs: 1000,
    trackerStaleAfterMs: 5000,
    trackerTeleportThreshold: 250,
    trackerMap: null,
    trackerMapRevision: null,
    trackerLastDeltaAt: 0,
    trackerBroadcasting: false,
    trackerRaf: null,
    trackerFrameAt: 0,
    trackerPanelAt: 0,
    trackerListSignature: '',
    trackerHomeSignature: '',
    mapPoisSignature: '',
    selectedUnitPlate: null,
    selectedDispatchCallId: null,
    operationalLayers: new Set(['dispatch', 'units', 'pois']),
    operationalCamera: null,
    citizenQuery: '',
    targetSource: null,
    processing: null,
    arrestPreview: null,
    arrestQuote: null,
    arrestReport: '',
    arrestCommitted: null,
    loading: new Set(),
    dirty: false,
    updatedAt: {},
    pending: new Map(),
    sequence: 0,
  };
  let activeConfirmation = null;
  let activePolicePanel = null;
  let navigationEnginePromise = null;
  let operationalMapReady = false;

  const codeLabels = {
    capability_denied: 'Você não tem permissão para esta operação.',
    duty_required: 'Entre em serviço para usar o MDT.',
    legal_rules_disabled: 'O catálogo jurídico está desativado.',
    records_unavailable: 'O serviço de registros está indisponível.',
    evidence_container_not_configured: 'O contêiner de evidências não está configurado.',
    evidence_association_disabled: 'A associação de evidências está desativada na configuração.',
    evidence_already_linked: 'Esta evidência já está vinculada ao caso.',
    organization_unavailable: 'O serviço de organizações está indisponível.',
    rate_limited: 'Muitas solicitações. Aguarde e tente novamente.',
    request_timeout: 'O servidor não respondeu dentro do limite.',
    revision_conflict: 'O caso foi alterado por outro operador. Atualize antes de salvar.',
    jurisdiction_disabled: 'A jurisdição policial ainda não foi aprovada.',
    legal_rule_not_configured: 'A acusação selecionada não está configurada.',
    prison_integration_disabled: 'A integração prisional está desativada.',
    intake_not_configured: 'O local de recebimento prisional não está configurado.',
    intake_point_required: 'Leve o cidadão ao ponto de recebimento configurado.',
    custody_required: 'O cidadão precisa estar sob sua custódia.',
    sentence_charge_not_found: 'A acusação selecionada não autoriza uma sentença.',
    sentence_rule_mismatch: 'Os catálogos policial e prisional não correspondem.',
    active_sentence_exists: 'O cidadão já possui uma sentença ativa.',
    arrest_disabled: 'A prisão rápida está desativada.',
    quick_arrest_disabled: 'A prisão rápida está desativada.',
    processing_not_configured: 'O ponto de processamento prisional não está configurado.',
    processing_point_required: 'Policial e custodiado precisam estar no ponto de processamento.',
    processing_point_mismatch: 'Policial e custodiado precisam estar no mesmo ponto de processamento.',
    report_too_short: 'O relato obrigatório está curto demais.',
    sentence_cap_not_configured: 'O teto da sentença multi-acusação não está configurado.',
    sentence_limit_exceeded: 'A soma das penas ultrapassa o teto configurado.',
    no_custodial_charge: 'Nenhuma acusação com pena foi selecionada.',
    citation_capability_required: 'Você não tem permissão para emitir a multa desta acusação.',
    notes_too_long: 'A observação é longa demais.',
    invalid_charge_count: 'Quantidade de acusações inválida.',
    invalid_charges: 'Selecione acusações válidas e distintas.',
    invalid_intake_context: 'O contexto de encaminhamento não é válido.',
    citation_not_payable: 'Esta multa não está pendente para pagamento.',
    citation_not_found: 'A multa não pertence ao cidadão selecionado.',
    dispatch_disabled: 'O dispatch está desativado na configuração.',
    dispatch_unavailable: 'O serviço de dispatch está indisponível.',
    tracker_disabled: 'O rastreamento de viaturas está desativado na configuração.',
    tracker_vehicle_not_allowed: 'O modelo desta viatura não está autorizado para transmissão.',
    vehicle_required: 'Entre em uma viatura autorizada para transmitir a posição.',
    vehicle_not_authorized: 'Esta viatura não está autorizada para rastreamento.',
    invalid_vehicle_plate: 'Informe uma placa válida.',
    vehicle_not_found: 'Nenhum veículo registrado foi encontrado para esta placa.',
    vehicle_unavailable: 'O registro canônico de veículos está indisponível.',
    invalid_coords: 'A localização do chamado não é válida.',
    waypoint_failed: 'Não foi possível marcar o destino no GPS.',
    assignment_required: 'Aceite o chamado antes de encerrá-lo.',
    call_closed: 'O chamado já foi encerrado.',
    forensics_disabled: 'A perícia avançada está desativada na configuração.',
    forensic_method_disabled: 'O método pericial ainda não foi aprovado.',
    forensic_method_not_applicable: 'Este método não se aplica à evidência selecionada.',
    evidence_not_linked: 'Vincule a evidência ao caso antes de solicitar a perícia.',
    evidence_not_in_custody: 'A evidência não está mais sob custódia no contêiner configurado.',
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
  let trackerRefreshTimer = null;
  let dataRefreshTimer = null;

  function icons() {
    if (window.lucide) window.lucide.createIcons({ attrs: { 'stroke-width': 1.7, 'aria-hidden': 'true' } });
  }

  function formatTime(date) {
    return new Intl.DateTimeFormat('pt-BR', { hour: '2-digit', minute: '2-digit', second: '2-digit' }).format(date);
  }

  function markUpdated(scope) {
    state.updatedAt[scope] = new Date();
    const latest = Object.values(state.updatedAt).filter((item) => item instanceof Date)
      .sort((left, right) => right - left)[0];
    syncStatus.textContent = latest ? `Atualizado ${formatTime(latest)}` : 'Aguardando sincronização';
    syncStatus.classList.toggle('is-live', Boolean(latest));
  }

  function toast(message, kind = 'info') {
    const item = document.createElement('div');
    item.className = `toast ${kind === 'error' ? 'error' : ''}`;
    item.textContent = message;
    toastRegion.appendChild(item);
    window.setTimeout(() => item.remove(), 4200);
  }

  function panelField(field, index) {
    const attributes = [
      field.required ? 'required' : '',
      Number.isFinite(Number(field.min)) ? `min="${Number(field.min)}"` : '',
      Number.isFinite(Number(field.max)) ? `max="${Number(field.max)}"` : '',
      `data-panel-field="${index}"`,
      `name="panel-field-${index}"`,
      'autocomplete="off"',
    ].filter(Boolean).join(' ');
    if (field.type === 'select') {
      return `<label class="panel-field"><span>${esc(field.label)}</span><select ${attributes}>${(field.options || []).map((option) =>
        `<option value="${esc(option.value)}" ${String(option.value) === String(field.default ?? '') ? 'selected' : ''}>${esc(option.label)}</option>`).join('')}</select></label>`;
    }
    if (field.type === 'textarea') {
      return `<label class="panel-field"><span>${esc(field.label)}</span><textarea ${attributes} placeholder="${esc(field.placeholder)}">${esc(field.default ?? '')}</textarea></label>`;
    }
    const type = field.type === 'number' ? 'number' : 'text';
    return `<label class="panel-field"><span>${esc(field.label)}</span><input type="${type}" ${attributes} value="${esc(field.default ?? '')}" placeholder="${esc(field.placeholder)}"></label>`;
  }

  function closePolicePanel(notifyClient = true) {
    const panel = activePolicePanel;
    if (!panel) return;
    activePolicePanel = null;
    app.inert = false;
    panelRoot.replaceChildren();
    panelRoot.classList.remove('is-open');
    panelRoot.setAttribute('aria-hidden', 'true');
    if (notifyClient && !preview) post('policePanelClose', { panelId: panel.id }).catch(() => {});
  }

  function openPolicePanel(panel) {
    if (!panel?.id) return;
    activePolicePanel = panel;
    app.inert = true;
    const isList = panel.kind === 'list';
    const isConfirm = panel.kind === 'confirm';
    const body = isList
      ? `<div class="panel-option-list">${(panel.options || []).map((option) => `<button class="panel-option ${option.destructive ? 'destructive' : ''}" type="button" data-panel-action="${esc(option.id)}" ${option.disabled ? 'disabled' : ''}>
          <i data-lucide="${esc(option.icon || 'chevron-right')}"></i><span><strong>${esc(option.title)}</strong>${option.description ? `<small>${esc(option.description)}</small>` : ''}</span>
        </button>`).join('')}</div>`
      : isConfirm
        ? `<p class="panel-confirm-copy">${esc(panel.subtitle)}</p>`
        : `<form id="police-panel-form" class="panel-form">${(panel.fields || []).map(panelField).join('')}</form>`;
    panelRoot.innerHTML = `<section class="police-panel" role="dialog" aria-modal="true" aria-labelledby="police-panel-title">
      <header><span class="kicker">MZ POLICE / AÇÃO OPERACIONAL</span><h2 id="police-panel-title">${esc(panel.title)}</h2>${!isConfirm && panel.subtitle ? `<p>${esc(panel.subtitle)}</p>` : ''}</header>
      <div class="police-panel-body">${body}</div>
      <footer class="police-panel-actions">
        <button class="button" type="button" data-panel-cancel>${esc(panel.cancelLabel || 'Fechar')}</button>
        ${isList ? '' : `<button class="button primary" type="button" data-panel-submit>${esc(panel.confirmLabel || 'Confirmar')}</button>`}
      </footer>
    </section>`;
    panelRoot.classList.add('is-open');
    panelRoot.setAttribute('aria-hidden', 'false');
    panelRoot.querySelector('[data-panel-cancel]')?.addEventListener('click', () => closePolicePanel(true));
    panelRoot.querySelectorAll('[data-panel-action]').forEach((button) => button.addEventListener('click', async () => {
      button.disabled = true;
      if (!preview) await post('policePanelSubmit', { panelId: panel.id, actionId: button.dataset.panelAction });
      closePolicePanel(false);
    }));
    panelRoot.querySelector('[data-panel-submit]')?.addEventListener('click', async () => {
      const fields = [...panelRoot.querySelectorAll('[data-panel-field]')];
      if (fields.some((field) => !field.reportValidity())) return;
      const payload = isConfirm
        ? { panelId: panel.id, confirmed: true }
        : { panelId: panel.id, values: fields.map((field) => field.value) };
      if (!preview) await post('policePanelSubmit', payload);
      closePolicePanel(false);
    });
    icons();
    panelRoot.querySelector('button:not([disabled]), input, select, textarea')?.focus();
  }

  function confirmAction({ title: titleText, message, confirmLabel = 'Confirmar' }) {
    if (activeConfirmation) return Promise.resolve(false);

    return new Promise((resolve) => {
      const previousFocus = document.activeElement;
      const overlay = document.createElement('div');
      overlay.className = 'confirmation-overlay';
      overlay.innerHTML = `<section class="confirmation-panel" role="alertdialog" aria-modal="true" aria-labelledby="confirmation-title" aria-describedby="confirmation-message" tabindex="-1">
        <span class="confirmation-kicker">CONFIRMAÇÃO NECESSÁRIA</span>
        <h2 id="confirmation-title"></h2>
        <p id="confirmation-message"></p>
        <div class="confirmation-actions">
          <button class="button" type="button" data-confirm-cancel>Cancelar</button>
          <button class="button primary" type="button" data-confirm-accept></button>
        </div>
      </section>`;
      overlay.querySelector('#confirmation-title').textContent = titleText;
      overlay.querySelector('#confirmation-message').textContent = message;
      const cancelButton = overlay.querySelector('[data-confirm-cancel]');
      const acceptButton = overlay.querySelector('[data-confirm-accept]');
      acceptButton.textContent = confirmLabel;

      const finish = (confirmed) => {
        if (activeConfirmation?.overlay !== overlay) return;
        activeConfirmation = null;
        terminal.inert = false;
        overlay.remove();
        if (state.open && previousFocus instanceof HTMLElement && previousFocus.isConnected) {
          previousFocus.focus();
        }
        resolve(confirmed);
      };

      activeConfirmation = { overlay, cancel: () => finish(false) };
      cancelButton.addEventListener('click', () => finish(false));
      acceptButton.addEventListener('click', () => finish(true));
      overlay.addEventListener('click', (event) => {
        if (event.target === overlay) finish(false);
      });
      overlay.addEventListener('keydown', (event) => {
        if (event.key === 'Escape') {
          event.preventDefault();
          event.stopPropagation();
          finish(false);
          return;
        }
        if (event.key !== 'Tab') return;
        event.preventDefault();
        const focusable = [cancelButton, acceptButton];
        const currentIndex = focusable.indexOf(document.activeElement);
        const direction = event.shiftKey ? -1 : 1;
        focusable[(currentIndex + direction + focusable.length) % focusable.length].focus();
      });
      terminal.inert = true;
      app.appendChild(overlay);
      cancelButton.focus();
    });
  }

  function setLoading(action, enabled) {
    if (enabled) state.loading.add(action); else state.loading.delete(action);
    loadingBar.hidden = state.loading.size === 0;
  }

  function routeTo(view) {
    const routes = {
      dashboard: ['home', 'home'], home: ['home', 'home'],
      dispatch: ['operations', 'operations'], units: ['operations', 'operations'], operations: ['operations', 'operations'],
      consultations: ['consultations', 'citizens'],
      citizens: ['consultations', 'citizens'], profile: ['consultations', 'profile'],
      citations: ['consultations', 'citations'], warrants: ['consultations', 'warrants'], history: ['consultations', 'history'],
      vehicles: ['vehicles', 'vehicles'], vehicle: ['vehicles', 'vehicles'],
      cases: ['cases', 'cases'], charges: ['cases', 'charges'], evidence: ['cases', 'evidence'],
    };
    const route = routes[view] || routes.home;
    if (state.active !== route[0] || state.view !== route[1]) state.dirty = false;
    state.active = route[0];
    state.view = route[1];
  }

  function loadNavigationAsset(tag, attributes) {
    return new Promise((resolve, reject) => {
      const node = document.createElement(tag);
      Object.entries(attributes).forEach(([key, item]) => node.setAttribute(key, item));
      node.addEventListener('load', resolve, { once: true });
      node.addEventListener('error', reject, { once: true });
      if (tag === 'link') {
        document.head.insertBefore(node, document.querySelector('link[href="style.css"]'));
      } else {
        document.head.appendChild(node);
      }
    });
  }

  function ensureNavigationEngine() {
    if (window.MZNavProjection && window.MZNavMap) return Promise.resolve(window.MZNavMap);
    if (navigationEnginePromise) return navigationEnginePromise;
    navigationEnginePromise = loadNavigationAsset('link', {
      rel: 'stylesheet', href: `${navigationAssetBase}/css/navigation.css`, 'data-mz-navigation': 'styles',
    }).catch(() => null)
      .then(() => loadNavigationAsset('script', { src: `${navigationAssetBase}/js/projection.js` }))
      .then(() => loadNavigationAsset('script', { src: `${navigationAssetBase}/js/map.js` }))
      .then(() => window.MZNavMap)
      .catch(() => null);
    return navigationEnginePromise;
  }

  async function post(endpoint, body) {
    const response = await fetch(`https://${resourceName}/${endpoint}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json; charset=UTF-8' }, body: JSON.stringify(body || {}),
    });
    return response.json();
  }

  function request(action, payload = {}) {
    if (preview) {
      const response = window.MZPolicePreview?.request?.(action, payload);
      return Promise.resolve(response || { ok: false, code: 'preview_only' });
    }
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
    return `<div class="data-list-table"><div class="data-list-head"><span>Ocorrência</span><span>Tipo</span><span>Estado</span></div><div class="data-list">${items.map((item) => `
      <button class="data-row" type="button" data-case-id="${esc(value(item, 'public_id', 'publicId'))}">
        <span><strong>${esc(item.title)}</strong><small>${esc(value(item, 'public_id', 'publicId'))}</small></span>
        <span>${esc(value(item, 'case_kind', 'caseKind') || 'case')}</span>
        <span class="status ${statusClass(item.status)}">${esc(item.status || 'unknown')}</span>
      </button>`).join('')}</div></div>`;
  }

  function operationalAlerts() {
    const alerts = [];
    const warrants = state.selectedCitizen?.police?.warrants || [];
    const activeWarrants = warrants.filter((item) => ['active', 'approved', 'open'].includes(String(item.status || '').toLowerCase()));
    if (activeWarrants.length) alerts.push({ kind: 'danger', icon: 'file-warning', title: 'Mandado ativo', detail: `${activeWarrants.length} no cidadão em contexto` });
    const vehicle = state.selectedVehicle?.vehicle;
    if (vehicle?.impounded) alerts.push({ kind: 'warning', icon: 'car-front', title: 'Veículo apreendido', detail: vehicle.plate });
    (vehicle?.flags || []).forEach((flag) => alerts.push({ kind: 'danger', icon: 'siren', title: flag.code.replaceAll('_', ' '), detail: flag.reference || vehicle.plate }));
    const support = (state.dispatch?.items || []).filter((item) => Number(value(item, 'priority_level', 'priorityLevel') || 3) <= 1);
    if (support.length) alerts.push({ kind: 'warning', icon: 'radio', title: 'Apoio prioritário', detail: `${support.length} chamado(s) na fila` });
    return alerts.slice(0, 3);
  }

  function renderAlertStrip() {
    const alerts = operationalAlerts();
    if (!alerts.length) return '<div class="alert-strip is-clear"><i data-lucide="shield-check"></i><span><strong>Sem alertas críticos no contexto atual</strong><small>O MDT destaca aqui somente dados confirmados.</small></span></div>';
    return `<div class="alert-strip">${alerts.map((alert) => `<div class="alert-item ${alert.kind}"><i data-lucide="${alert.icon}"></i><span><strong>${esc(alert.title)}</strong><small>${esc(alert.detail)}</small></span></div>`).join('')}</div>`;
  }

  function renderDashboard() {
    const selected = state.selectedCitizen;
    const calls = (state.dispatch?.items || []).filter((item) => !['closed', 'cancelled'].includes(String(item.status || '').toLowerCase()));
    const units = state.trackerSnapshot?.units || [];
    const warrants = (selected?.police?.warrants || []).filter((item) => ['active', 'approved', 'open'].includes(String(item.status || '').toLowerCase()));
    return `<div class="stack dashboard-view">
      ${preview ? '<div class="notice">Preview visual isolado. Nenhum registro real foi carregado.</div>' : ''}
      ${renderAlertStrip()}
      <div class="metrics metrics--dashboard">
        <div class="metric accent"><span>CHAMADOS ABERTOS</span><strong>${calls.length}</strong><small>fila confirmada</small></div>
        <div class="metric"><span>UNIDADES EM SERVIÇO</span><strong>${units.length}</strong><small>transmitindo</small></div>
        <div class="metric ${warrants.length ? 'danger' : ''}"><span>MANDADOS EM CONTEXTO</span><strong>${warrants.length}</strong><small>${selected ? 'cidadão selecionado' : 'sem cidadão'}</small></div>
        <div class="metric"><span>CASOS CARREGADOS</span><strong>${state.cases.length}</strong><small>página atual</small></div>
      </div>
      <div class="dashboard-grid">
        <section class="panel dashboard-cases">
          <div class="panel-header"><div><h2>Últimas ocorrências</h2><p>Registros autorizados da organização ativa.</p></div><button class="button" data-go="cases"><i data-lucide="arrow-right"></i>Ver todos</button></div>
          ${caseRows(state.cases.slice(0, 8))}
        </section>
        <aside class="stack dashboard-side">
          <section class="panel"><div class="panel-header"><div><h2>Unidades em serviço</h2><p>${units.length} transmissão(ões) autorizada(s).</p></div><button class="button" data-go="operations">Ver mapa</button></div>${units.length ? `<div class="compact-list">${units.slice(0, 6).map((unit) => `<div><span class="signal"></span><strong>${esc(unit.plate || 'Sem placa')}</strong><small>Sinal ativo</small></div>`).join('')}</div>` : empty('Sem transmissão', 'Nenhuma unidade está transmitindo agora.', 'radio')}</section>
          <section class="panel"><div class="panel-header"><div><h2>Contexto rápido</h2><p>Dados sensíveis permanecem visíveis.</p></div></div><div class="panel-body context-summary"><div><span>Cidadão</span><strong>${selected ? esc(nameOf(selected.citizen || {})) : 'Nenhum selecionado'}</strong></div><div><span>Veículo</span><strong>${state.selectedVehicle?.vehicle ? esc(state.selectedVehicle.vehicle.plate) : 'Nenhum consultado'}</strong></div></div></section>
        </aside>
      </div>
    </div>`;
  }

  function renderCitizens() {
    const result = state.citizenSearch;
    const items = result?.items || [];
    return `<div class="stack citizen-search-layout">
      <div class="panel results-panel">
        <div class="panel-header"><div><h2>Consulta de cidadãos</h2><p>Nome ou identificador, mínimo de dois caracteres.</p></div></div>
        <form id="citizen-search-form" class="panel-body toolbar">
          <div class="field"><label for="citizen-query">Termo de busca</label><input id="citizen-query" name="query" maxlength="64" autocomplete="off" placeholder="Nome ou citizen ID…" value="${esc(state.citizenQuery)}" required></div>
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

  function renderVehicles() {
    const vehicle = state.selectedVehicle?.vehicle;
    const flags = vehicle?.flags || [];
    const ownerName = vehicle?.owner ? nameOf(vehicle.owner) : vehicle?.ownerId || 'Não informado';
    return `<div class="stack vehicle-view">
      <section class="panel search-panel">
        <div class="panel-header"><div><h2>Consulta de veículo</h2><p>Informe a placa completa. O registro vem do owner canônico mz_vehicles.</p></div></div>
        <form id="vehicle-search-form" class="panel-body toolbar"><div class="field"><label for="vehicle-query">Placa</label><input id="vehicle-query" name="plate" maxlength="16" autocomplete="off" placeholder="ABC1D23" value="${esc(state.vehicleQuery)}" required></div><button class="button primary" type="submit"><i data-lucide="search"></i>Consultar</button></form>
      </section>
      ${vehicle ? `<section class="vehicle-result">
        <div class="vehicle-identity"><span class="vehicle-mark"><i data-lucide="car-front"></i></span><div><span>REGISTRO VEICULAR</span><h2>${esc(vehicle.plate)}</h2><p>${esc(vehicle.model || 'Modelo não informado')}</p></div><span class="status ${vehicle.impounded ? 'cancelled' : 'approved'}">${vehicle.impounded ? 'APREENDIDO' : esc(vehicle.state || 'REGISTRADO')}</span></div>
        ${flags.length ? `<div class="alert-strip">${flags.map((flag) => `<div class="alert-item danger"><i data-lucide="siren"></i><span><strong>${esc(flag.code.replaceAll('_', ' '))}</strong><small>${esc(flag.reference || 'Alerta policial ativo')}</small></span></div>`).join('')}</div>` : ''}
        <div class="details-grid vehicle-details"><div class="detail"><span>Proprietário</span><strong>${esc(ownerName)}</strong><small>${esc(vehicle.ownerId || '')}</small></div><div class="detail"><span>Estado</span><strong>${esc(vehicle.state || 'Não informado')}</strong></div><div class="detail"><span>Garagem</span><strong>${esc(vehicle.garage || 'Não informada')}</strong></div></div>
      </section>` : `<section class="panel">${empty('Nenhum veículo consultado', 'Use a placa para consultar proprietário, estado e alertas.', 'car-front')}</section>`}
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
    const sentence = state.sentence?.sentence;
    const initials = nameOf(citizen).split(/\s+/).slice(0, 2).map((part) => part[0]).join('').toUpperCase();
    const activeWarrants = (police.warrants || []).filter((item) => ['active', 'approved', 'open'].includes(String(item.status || '').toLowerCase()));
    return `<div class="stack">
      ${activeWarrants.length ? `<div class="alert-strip"><div class="alert-item danger"><i data-lucide="file-warning"></i><span><strong>Mandado ativo</strong><small>${activeWarrants.length} registro(s) exige(m) atenção imediata.</small></span></div></div>` : ''}
      <div class="panel"><div class="panel-body profile-head">
        <div class="profile-identity"><div class="profile-photo" aria-label="Foto do cidadão indisponível"><span>${esc(initials)}</span><small>SEM FOTO</small></div><div><h2 class="profile-name">${esc(nameOf(citizen))}</h2><div class="profile-id">${esc(citizen.citizenid)}</div></div></div>
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
      <div class="panel">
        <div class="panel-header"><div><h2>Situação prisional</h2><p>Consulta ao registro prisional autorizado.</p></div><button id="load-sentence" class="button" type="button"><i data-lucide="refresh-cw"></i>Consultar</button></div>
        <div class="panel-body">${sentence
          ? `<div class="details-grid sentence-grid"><div class="detail"><span>Estado</span><strong>${esc(sentence.status || (sentence.active === false ? 'sem sentença ativa' : 'desconhecido'))}</strong></div><div class="detail"><span>Tempo restante</span><strong>${esc(value(sentence, 'remaining_seconds', 'remainingSeconds') ?? 'Não informado')}</strong></div><div class="detail"><span>Sentença</span><strong>${esc(value(sentence, 'public_id', 'publicId') || 'Não informada')}</strong></div><div class="detail"><span>Acusações na sentença</span><strong>${esc((sentence.charges || []).length)}</strong></div></div>`
          : '<div class="notice">Consulte a situação antes de preparar um novo encaminhamento.</div>'}</div>
      </div>
    </div>`;
  }

  function renderCaseEditor() {
    const current = state.selectedCase;
    if (!current) return `<div class="panel">
      <div class="panel-header"><div><h2>Novo registro</h2><p>Etapa <span id="case-step-label">1</span> de 2 · identificação e relato.</p></div></div>
      <form id="case-create-form" class="panel-body">
        <fieldset class="form-grid form-step" data-case-step-panel="1">
          <legend class="sr-only">Identificação da ocorrência</legend>
          <div class="field"><label for="case-kind">Tipo</label><select id="case-kind" name="kind" autocomplete="off"><option value="occurrence">Ocorrência</option><option value="investigation">Investigação</option><option value="case">Caso</option></select></div>
          <div class="field"><label for="case-title">Título</label><input id="case-title" name="title" maxlength="160" autocomplete="off" required></div>
        </fieldset>
        <fieldset class="form-grid form-step" data-case-step-panel="2" hidden>
          <legend class="sr-only">Relato da ocorrência</legend><div class="field wide"><label for="case-summary">Resumo</label><textarea id="case-summary" name="summary" maxlength="8000" autocomplete="off" placeholder="Descreva os fatos confirmados e o contexto operacional."></textarea></div>
        </fieldset>
        <div class="form-actions"><button class="button" type="button" data-case-step="back" hidden><i data-lucide="arrow-left"></i>Voltar</button><button class="button primary" type="button" data-case-step="next">Continuar<i data-lucide="arrow-right"></i></button><button class="button primary" type="submit" data-case-step="submit" hidden><i data-lucide="folder-plus"></i>Criar registro</button></div>
      </form>
    </div>`;

    const caseId = value(current, 'public_id', 'publicId');
    const people = current.people || [];
    const officers = current.officers || [];
    const history = current.history || [];
    const quickArrest = history.some((item) => item.action === 'quick_arrest_created');
    return `<div class="stack">
      ${quickArrest ? '<div class="notice">Registro criado pela prisão rápida. O caso pode ser complementado normalmente no MDT.</div>' : ''}
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
      <div class="split">
        <div class="panel">
          <div class="panel-header"><div><h2>Policiais responsáveis</h2><p>Vínculo persistido pelo domínio policial.</p></div></div>
          ${officers.length ? `<div class="data-list">${officers.map((officer) => `<div class="data-row"><span><strong>${esc(officer.citizenid)}</strong><small>${esc(officer.role)}</small></span><span>${esc(formatDate(value(officer, 'created_at', 'createdAt')))}</span><span class="status">${esc(officer.role === 'creator' ? 'CRIADOR' : 'VÍNCULO')}</span></div>`).join('')}</div>` : empty('Sem policiais vinculados', 'O caso não possui responsáveis persistidos.', 'shield')}
        </div>
        <div class="panel">
          <div class="panel-header"><div><h2>Histórico do caso</h2><p>Trilha durável das decisões do registro.</p></div></div>
          ${history.length ? `<div class="data-list">${history.map((item) => `<div class="data-row"><span><strong>${esc(item.action)}</strong><small>${esc(value(item, 'actor_citizenid', 'actorCitizenid') || 'sistema')}</small></span><span>${esc(formatDate(value(item, 'created_at', 'createdAt')))}</span><span class="status">AUDITADO</span></div>`).join('')}</div>` : empty('Sem histórico', 'Nenhuma decisão foi registrada neste caso.', 'history')}
        </div>
      </div>
    </div>`;
  }

  function renderCases() {
    const now = Date.now();
    const maximumAge = state.caseFilter.period === 'day' ? 86400000 : state.caseFilter.period === 'week' ? 604800000 : Infinity;
    const filtered = state.cases.filter((item) => {
      const kind = value(item, 'case_kind', 'caseKind') || 'case';
      const created = new Date(value(item, 'created_at', 'createdAt') || 0).getTime();
      return (state.caseFilter.kind === 'all' || kind === state.caseFilter.kind)
        && (maximumAge === Infinity || (Number.isFinite(created) && now - created <= maximumAge));
    });
    return `<div class="case-workspace">
      <section id="case-list-panel" class="panel case-list-panel">
        <div class="panel-header"><div><h2>Casos e ocorrências</h2><p>${filtered.length} de ${state.cases.length} registro(s) carregado(s).</p></div><button id="reload-cases" class="button" type="button"><i data-lucide="refresh-cw"></i>Atualizar</button></div>
        <div class="filter-bar" role="group" aria-label="Filtros de casos"><label>Tipo<select id="case-filter-kind"><option value="all" ${state.caseFilter.kind === 'all' ? 'selected' : ''}>Todos</option><option value="occurrence" ${state.caseFilter.kind === 'occurrence' ? 'selected' : ''}>Ocorrências</option><option value="investigation" ${state.caseFilter.kind === 'investigation' ? 'selected' : ''}>Investigações</option><option value="case" ${state.caseFilter.kind === 'case' ? 'selected' : ''}>Casos</option></select></label><label>Período<select id="case-filter-period"><option value="all" ${state.caseFilter.period === 'all' ? 'selected' : ''}>Todo o período</option><option value="day" ${state.caseFilter.period === 'day' ? 'selected' : ''}>Últimas 24h</option><option value="week" ${state.caseFilter.period === 'week' ? 'selected' : ''}>Últimos 7 dias</option></select></label></div>
        <div class="scroll-region">${caseRows(filtered)}</div>
      </section>
      <section class="case-detail-region">${renderCaseEditor()}</section>
      </div>
    `;
  }

  function renderArrestProcessing() {
    if (!state.processing) return '';
    if (state.arrestCommitted) {
      return `<div class="panel"><div class="panel-header"><div><h2>Processamento concluído</h2><p>${esc(state.arrestCommitted.caseId)}</p></div><span class="status active">PENDENTE DE INTAKE</span></div><div class="panel-body"><div class="notice">Caso e acusações persistidos. Conduza o custodiado ao intake prisional configurado.</div></div></div>`;
    }
    const previewData = state.arrestPreview;
    if (!previewData) return `<div class="panel"><div class="panel-header"><div><h2>Processamento prisional</h2><p>Ponto ${esc(state.processing.pointId || '')}</p></div></div><div class="panel-body"><div class="notice">Carregando catálogo e contexto de custódia…</div></div></div>`;
    const charges = previewData.catalog?.charges || [];
    const maxCharges = Number(previewData.limits?.maxCharges || 1);
    const minReport = Number(previewData.limits?.minimumReportLength || 1);
    const maxReport = Number(previewData.limits?.maximumNotesLength || 4000);
    const quote = state.arrestQuote;
    return `<div class="panel"><div class="panel-header"><div><h2>Processamento prisional</h2><p>${esc(previewData.target?.name || 'Custodiado')} · ponto ${esc(state.processing.pointId || '')}</p></div><span class="status">ATÉ ${esc(maxCharges)} ACUSAÇÕES</span></div>
      <form id="arrest-processing-form" class="panel-body stack">
        <fieldset class="charge-grid"><legend>Acusações canônicas</legend>${charges.map((charge) => `<label class="check-row"><input type="checkbox" name="arrest-rule" value="${esc(charge.code)}"><span><strong>${esc(charge.name)}</strong><small>${esc(charge.sentenceSeconds)}s · ${money(charge.fineAmount)}</small></span></label>`).join('')}</fieldset>
        <div class="field"><label for="arrest-report">Relato obrigatório</label><textarea id="arrest-report" name="report" minlength="${esc(minReport)}" maxlength="${esc(maxReport)}" autocomplete="off" required placeholder="Descreva fatos e fundamento do processamento…">${esc(state.arrestReport)}</textarea><small>Mínimo de ${esc(minReport)} caracteres.</small></div>
        ${quote ? `<div class="notice"><strong>Prévia confirmada:</strong> ${esc(quote.totals?.sentenceSeconds || 0)}s · ${money(quote.totals?.fineAmount || 0)} · ${esc(quote.totals?.chargeCount || 0)} acusação(ões).</div>` : ''}
        <div class="form-actions"><button class="button" type="submit"><i data-lucide="calculator"></i>Calcular</button>${quote ? '<button id="confirm-arrest-processing" class="button primary" type="button"><i data-lucide="shield-check"></i>Confirmar processamento</button>' : ''}</div>
      </form></div>`;
  }

  function renderCharges() {
    const current = state.selectedCase;
    const processingPanel = renderArrestProcessing();
    if (!current) return processingPanel || unavailable('Acusações indisponíveis', 'Abra um caso para visualizar acusações persistidas.');
    const charges = current.charges || [];
    const citizenid = state.selectedCitizen?.citizen?.citizenid;
    const catalog = state.legalCatalog?.charges || [];
    const eligible = charges.filter((item) => String(item.citizenid || '') === String(citizenid || '') && Number(value(item, 'sentence_seconds', 'sentenceSeconds') || 0) > 0);
    const intakeNotice = !state.targetSource
      ? 'Contexto do alvo ausente: feche o MDT e abra-o pelo radial "Abrir ficha no MDT".'
      : !citizenid
        ? 'Selecione o cidadão na ficha para vincular a acusação ao alvo online.'
        : eligible.length === 0
          ? 'Nenhuma acusação com pena configurada para este cidadão. Adicione uma acusação do catálogo e tente novamente.'
          : null;
    return `<div class="stack">${processingPanel}
      <div class="notice">Somente regras habilitadas pelo servidor são selecionáveis. Pena e multa nunca são enviadas pelo cliente.</div>
      <div class="panel">
        <div class="panel-header"><div><h2>Nova acusação</h2><p>${catalog.length ? `Catálogo ${esc(state.legalCatalog.legalVersion)}` : 'Carregue o catálogo aprovado.'}</p></div><button id="load-legal-catalog" class="button" type="button"><i data-lucide="book-open-check"></i>Carregar catálogo</button></div>
        ${catalog.length && citizenid ? `<form id="charge-form" class="panel-body toolbar"><div class="field"><label for="charge-rule">Regra canônica</label><select id="charge-rule" name="ruleCode" autocomplete="off">${catalog.map((rule) => `<option value="${esc(rule.code)}" title="${esc(rule.description || '')}">${esc(rule.category || '')}${rule.category ? ' · ' : ''}${esc(rule.name)} · ${esc(rule.sentenceSeconds)}s · ${money(rule.fineAmount)}</option>`).join('')}</select></div><button class="button primary" type="submit"><i data-lucide="scale"></i>Adicionar ao caso</button></form>` : `<div class="panel-body"><div class="notice">${citizenid ? 'Catálogo não carregado ou desativado.' : 'Selecione um cidadão antes de registrar acusação.'}</div></div>`}
      </div>
      <div class="panel"><div class="panel-header"><div><h2>Acusações do caso</h2><p>${esc(value(current, 'public_id', 'publicId'))}</p></div></div>${charges.length ? `<div class="data-list">${charges.map((item) => `<div class="data-row"><span><strong>${esc(value(item, 'rule_name', 'ruleName'))}</strong><small>${esc(value(item, 'public_id', 'publicId'))}</small></span><span>${esc(value(item, 'rule_code', 'ruleCode'))} · ${money(value(item, 'fine_amount', 'fineAmount') || 0)}</span><span class="status">${esc(value(item, 'legal_version', 'legalVersion'))}</span></div>`).join('')}</div>` : empty('Sem acusações', 'O caso não possui acusações persistidas.', 'scale')}</div>
      <div class="panel"><div class="panel-header"><div><h2>Encaminhamento prisional</h2><p>A confirmação ocorre somente no ponto de intake configurado.</p></div></div>
        ${state.targetSource && eligible.length ? `<div class="data-list">${eligible.map((item) => `<div class="data-row"><span><strong>${esc(value(item, 'rule_name', 'ruleName'))}</strong><small>${esc(value(item, 'public_id', 'publicId'))}</small></span><span>${esc(value(item, 'sentence_seconds', 'sentenceSeconds'))}s</span><span><button class="button" type="button" data-prepare-intake="${esc(value(item, 'public_id', 'publicId'))}"><i data-lucide="building-2"></i>Preparar intake</button></span></div>`).join('')}</div>` : `<div class="panel-body"><div class="notice">${esc(intakeNotice)}</div></div>`}
      </div>
    </div>`;
  }

  function renderCitizenCollection(key, label, icon, row) {
    const missing = selectedCitizenRequired(label);
    if (missing) return missing;
    const collection = state.selectedCitizen.police?.[key] || [];
    return `<div class="stack"><div class="notice">Novos registros ficam indisponíveis enquanto o catálogo jurídico não estiver aprovado. A tela mostra somente dados confirmados.</div><div class="panel"><div class="panel-header"><div><h2>${esc(label)}</h2><p>Contexto do cidadão selecionado.</p></div></div>${collection.length ? `<div class="data-list">${collection.map(row).join('')}</div>` : empty(`Sem ${label.toLowerCase()}`, 'Nenhum registro foi retornado para este cidadão.', icon)}</div></div>`;
  }

  function renderCitations() {
    return renderCitizenCollection('citations', 'Multas', 'receipt-text', (item) => {
      const citationId = value(item, 'public_id', 'publicId');
      const canRequest = state.targetSource && item.status === 'pending';
      return `<div class="data-row"><span><strong>${esc(value(item, 'rule_name', 'ruleName'))}</strong><small>${esc(citationId)}</small></span><span>${money(item.amount)}</span><span class="dispatch-actions"><span class="status ${statusClass(item.status)}">${esc(item.status)}</span>${canRequest ? `<button class="button" type="button" data-request-citation-payment="${esc(citationId)}"><i data-lucide="hand-coins"></i>Solicitar pagamento</button>` : ''}</span></div>`;
    });
  }

  function renderWarrants() {
    return renderCitizenCollection('warrants', 'Mandados', 'file-warning', (item) => {
      const active = ['active', 'approved', 'open'].includes(String(item.status || '').toLowerCase());
      return `<div class="data-row warrant-row ${active ? 'is-critical' : ''}"><span><strong>${esc(value(item, 'rule_name', 'ruleName'))}</strong><small>${esc(value(item, 'public_id', 'publicId'))}</small></span><span>${active ? 'GRAVIDADE ALTA' : 'SEM ALERTA ATIVO'} · ${esc(value(item, 'case_public_id', 'casePublicId'))}</span><span class="status ${active ? 'cancelled' : statusClass(item.status)}">${esc(item.status)}</span></div>`;
    });
  }

  function renderEvidence() {
    const evidence = state.evidence;
    const items = evidence?.items || [];
    const linked = state.selectedCase?.evidence || [];
    const forensics = state.selectedCase?.forensics || [];
    const caseHistory = (state.selectedCase?.history || []).filter((item) => item.action === 'evidence_linked');
    const caseId = value(state.selectedCase, 'public_id', 'publicId');
    const associationEnabled = evidence?.associationEnabled === true;
    const linkNotice = associationEnabled
      ? (caseId ? `Vínculo autorizado disponível para o caso ${esc(caseId)}.` : 'Abra um caso antes de vincular uma evidência.')
      : 'A associação está desativada até aprovação explícita da configuração.';
    return `<div class="stack">
      <div class="notice">${linkNotice}</div>
      <div class="panel"><div class="panel-header"><div><h2>Evidências vinculadas ao caso</h2><p>${caseId ? esc(caseId) : 'Nenhum caso selecionado.'}</p></div></div>
        ${linked.length ? `<div class="data-list">${linked.map((item) => {
          const uid = value(item, 'instance_uid', 'instanceUid');
          const current = items.find((candidate) => value(candidate, 'instanceUid', 'instance_uid') === uid);
          const canAnalyze = evidence?.forensicsEnabled === true && current?.forensics?.kind === 'weapon' && current?.forensics?.serial;
          return `<div class="data-row"><span><strong>${esc(item.label || item.item)}</strong><small>${esc(value(item, 'evidence_id', 'evidenceId'))}</small></span><span>${esc(value(item, 'linked_by_citizenid', 'linkedByCitizenid'))}</span><span>${canAnalyze ? `<button class="button" type="button" data-forensic-analyze="${esc(uid)}"><i data-lucide="fingerprint"></i>Identificar arma</button>` : `<span class="status">REV ${esc(value(item, 'linked_evidence_revision', 'linkedEvidenceRevision'))}</span>`}</span></div>`;
        }).join('')}</div>` : empty('Sem evidências vinculadas', 'Abra um caso para consultar seus vínculos persistidos.', 'link')}</div>
      <div class="panel"><div class="panel-header"><div><h2>Resultados periciais</h2><p>Somente resultados derivados de metadados canônicos.</p></div></div>
        ${forensics.length ? `<div class="data-list">${forensics.map((item) => {
          let result = {};
          try { result = JSON.parse(value(item, 'result_json', 'resultJson') || '{}'); } catch (_) { result = {}; }
          return `<div class="data-row"><span><strong>${esc(item.method)}</strong><small>${esc(value(item, 'evidence_id', 'evidenceId'))}</small></span><span>${esc(result.serial || 'Resultado indisponível')}</span><span class="status ${statusClass(item.status)}">${esc(item.status)}</span></div>`;
        }).join('')}</div>` : empty('Sem resultados periciais', 'GSR, impressões e balística não são inferidos sem produtores confiáveis.', 'fingerprint')}</div>
      <div class="panel"><div class="panel-header"><div><h2>Histórico de vínculos</h2><p>Trilha persistida pelo domínio policial.</p></div></div>
        ${caseHistory.length ? `<div class="data-list">${caseHistory.map((item) => `<div class="data-row"><span><strong>Evidência vinculada</strong><small>${esc(value(item, 'actor_citizenid', 'actorCitizenid'))}</small></span><span>${esc(formatDate(value(item, 'created_at', 'createdAt')))}</span><span class="status">AUDITADO</span></div>`).join('')}</div>` : empty('Sem histórico de vínculos', 'Nenhuma associação foi registrada neste caso.', 'history')}</div>
      <div class="panel"><div class="panel-header"><div><h2>Recebimento de evidências</h2><p>Itens disponíveis para cadeia de custódia.</p></div><button id="load-evidence" class="button" type="button"><i data-lucide="scan-barcode"></i>Consultar recebimento</button></div>
        ${items.length ? `<div class="data-list">${items.map((item) => {
          const metadata = item.evidence || {};
          const uid = value(item, 'instanceUid', 'instance_uid');
          return `<div class="data-row"><span><strong>${esc(item.label || item.item || 'Item de evidência')}</strong><small>${esc(uid)}</small></span><span>${esc(value(metadata, 'evidenceId', 'evidence_id') || 'Identificado')}</span><span>${associationEnabled && caseId ? `<button class="button" type="button" data-evidence-link="${esc(uid)}"><i data-lucide="link"></i>Vincular</button>` : `<span class="status">REV ${esc(value(metadata, 'revision') || 1)}</span>`}</span></div>`;
        }).join('')}</div>` : empty('Nenhuma evidência carregada', 'Consulte o recebimento. A operação exige permissão própria.', 'scan-barcode')}
      </div>
    </div>`;
  }

  function renderHistory() {
    const missing = selectedCitizenRequired('Histórico');
    if (missing) return missing;
    const items = state.selectedCitizen.police?.history || [];
    return `<div class="panel"><div class="panel-header"><div><h2>Histórico de ações</h2><p>Trilha durável do cidadão no domínio policial.</p></div></div>${items.length ? `<div class="data-list">${items.map((item) => `<div class="data-row"><span><strong>${esc(item.action)}</strong><small>${esc(value(item, 'entity_id', 'entityId'))}</small></span><span>${esc(value(item, 'actor_citizenid', 'actorCitizenid'))}</span><span>${esc(formatDate(value(item, 'created_at', 'createdAt')))}</span></div>`).join('')}</div>` : empty('Sem histórico', 'Nenhuma ação policial foi retornada para este cidadão.', 'history')}</div>`;
  }

  function dispatchLocation(item) {
    const x = Number(value(item, 'location_x', 'locationX'));
    const y = Number(value(item, 'location_y', 'locationY'));
    if (!Number.isFinite(x) || !Number.isFinite(y)) return 'Local não informado';
    return `X ${x.toFixed(1)} · Y ${y.toFixed(1)}`;
  }

  function renderDispatchQueue() {
    const queue = state.dispatch;
    const items = queue?.items || [];
    const loading = state.loading.has('dispatchList');
    return `<div class="panel-header"><div><h2>Fila operacional</h2><p>Chamados autorizados pelo dispatch.</p></div><button id="reload-dispatch" class="button" type="button"${loading ? ' disabled' : ''}><i data-lucide="refresh-cw"></i>${loading ? 'Atualizando…' : 'Atualizar'}</button></div>
        ${items.length ? `<div class="data-list">${items.map((item) => {
          const callId = value(item, 'public_id', 'publicId');
          const service = value(item, 'service_code', 'serviceCode') || 'origem não informada';
          const createdAt = formatDate(value(item, 'created_at', 'createdAt'));
          const classification = `${value(item, 'category_code', 'categoryCode') || 'ocorrência'} · P${Number(value(item, 'priority_level', 'priorityLevel') || 3)}`;
          const selected = String(state.selectedDispatchCallId || '') === String(callId);
          return `<div class="data-row operational-row${selected ? ' is-selected' : ''}">
            <button class="operational-row__select" type="button" data-select-call="${esc(callId)}"><strong>${esc(item.message)}</strong><small>${esc(classification)} · ${esc(callId)} · ${esc(service)} · ${esc(createdAt)}</small></button>
            <span>${esc(Number(value(item, 'assigned_units', 'assignedUnits') || 0))} unidade(s)<small>${esc(dispatchLocation(item))}</small></span>
            <span class="dispatch-actions"><span class="status ${statusClass(item.status)}">${esc(item.status)}</span><button class="button" type="button" data-dispatch-waypoint="${esc(callId)}"><i data-lucide="map-pin"></i>Abrir GPS</button><button class="button" type="button" data-dispatch-accept="${esc(callId)}"><i data-lucide="radio"></i>Aceitar</button><button class="button" type="button" data-dispatch-close="${esc(callId)}"><i data-lucide="check-circle"></i>Encerrar</button></span>
          </div>`;
        }).join('')}</div>` : empty(loading ? 'Carregando chamados' : 'Nenhum chamado aberto', loading ? 'Consultando a central…' : queue ? 'A fila policial está vazia.' : 'Atualize para consultar a central.', 'radio-tower')}`;
  }

  function renderUnitsList() {
    const snapshot = state.trackerSnapshot;
    if (snapshot && snapshot.ok !== true) {
      return empty('Rastreamento indisponível', messageFor(snapshot), 'map');
    }
    const units = snapshot?.units || [];
    const loading = state.loading.has('trackerSnapshot');
    const toggling = state.loading.has('trackerBroadcast');
    const unitCountLabel = units.length === 1 ? '1 unidade transmitindo' : `${units.length} unidades transmitindo`;
    const list = units.length
      ? `<div class="tracker-units" role="list">${units.map((unit, index) => {
        const selected = state.selectedUnitPlate === unit.plate;
        const plate = unit.plate || `Unidade ${index + 1}`;
        const coords = unit.coordinates || unit;
        const x = Number(coords.x);
        const y = Number(coords.y);
        const location = Number.isFinite(x) && Number.isFinite(y) ? `X ${x.toFixed(0)} · Y ${y.toFixed(0)}` : 'Coordenadas indisponíveis';
        const statusText = unit.status === 'stale' ? 'ATRASADO' : unit.status === 'offduty' ? 'FORA DE SERVIÇO' : 'SINAL ATIVO';
        return `<button class="tracker-unit${selected ? ' is-selected' : ''}${unit.status === 'stale' ? ' is-stale' : ''}" type="button" data-unit-id="${esc(unit.id || '')}" data-unit-plate="${esc(plate)}" aria-pressed="${selected}"><span class="tracker-unit__signal" aria-hidden="true"></span><span class="tracker-unit__copy"><strong>${esc(plate)}</strong><small>${esc(location)}</small></span><span class="tracker-unit__state">${esc(statusText)}</span></button>`;
      }).join('')}</div>`
      : `<div class="tracker-empty"><i data-lucide="${loading ? 'loader-circle' : 'radio'}"></i><strong>${loading ? 'Consultando unidades' : 'Nenhuma viatura transmitindo'}</strong><span>${loading ? 'Aguardando atualização autorizada.' : 'A lista mostra apenas unidades autorizadas no seu setor.'}</span></div>`;
    return `<div class="panel-header"><div><h2>Unidades</h2><p>${snapshot ? unitCountLabel : 'Aguardando snapshot'} no seu setor autorizado.</p></div><button id="toggle-tracker" class="button" type="button"${loading || toggling ? ' disabled' : ''}><i data-lucide="radio-tower"></i>${toggling ? 'Atualizando…' : snapshot?.broadcasting ? 'Parar transmissão' : 'Transmitir viatura'}</button></div>
      ${list}<p class="tracker-note">Transmissão voluntária; a autorização é validada pelo servidor.</p>`;
  }

  function operationalMapData() {
    const map = state.trackerMap || state.trackerSnapshot?.map;
    const calls = state.dispatch?.items || [];
    const legacyUnits = state.trackerV2 ? [] : (state.trackerSnapshot?.units || []);
    const layers = [
      { id: 'dispatch', label: 'Chamados' },
      { id: 'units', label: 'Viaturas' },
      ...(map?.layers || []),
    ];
    const pois = [
      ...calls.map((call) => ({
        id: `dispatch:${value(call, 'public_id', 'publicId')}`,
        layer: 'dispatch', label: call.message || 'Chamado', kind: 'dispatch',
        x: Number(value(call, 'location_x', 'locationX')),
        y: Number(value(call, 'location_y', 'locationY')),
        z: Number(value(call, 'location_z', 'locationZ')) || 0,
      })),
      ...legacyUnits.map((unit) => ({
        id: `unit:${unit.unitId || unit.plate}`,
        layer: 'units', label: `Viatura ${unit.plate || 'sem placa'}`, kind: 'unit',
        plate: unit.plate, x: Number(unit.coordinates?.x), y: Number(unit.coordinates?.y),
        z: Number(unit.coordinates?.z) || 0,
      })),
      ...(map?.pois || []).map((poi) => ({ ...poi, kind: 'poi' })),
    ].filter((poi) => Number.isFinite(poi.x) && Number.isFinite(poi.y));
    const visible = new Set();
    if (state.operationalLayers.has('dispatch')) visible.add('dispatch');
    if (state.operationalLayers.has('units')) visible.add('units');
    if (state.operationalLayers.has('pois')) (map?.layers || []).forEach((layer) => visible.add(layer.id));
    return { map, layers, pois, visible };
  }

  function syncOperationalMapLayers() {
    if (!operationalMapReady) return;
    const data = operationalMapData();
    window.MZNavMap?.setData(data.pois, data.layers);
    window.MZNavMap?.setVisibleLayers(data.visible);
    window.MZNavMap?.setPoliceVisible(state.operationalLayers.has('units'));
  }

  function displayedTrackerUnits() {
    const now = performance.now();
    const units = [];
    for (const unit of state.trackerUnits.values()) {
      const sampled = trackerMath
        ? trackerMath.sample(unit, now, state.trackerStaleAfterMs)
        : { x: unit.toX, y: unit.toY, z: unit.toZ, heading: unit.toHeading, status: unit.status };
      units.push({
        ...unit,
        x: sampled.x,
        y: sampled.y,
        z: sampled.z,
        heading: sampled.heading,
        status: sampled.status,
        coordinates: { x: sampled.x, y: sampled.y, z: sampled.z },
      });
    }
    return units;
  }

  function syncTrackerSnapshot() {
    const units = displayedTrackerUnits();
    state.trackerSnapshot = {
      ok: true,
      units,
      map: state.trackerMap,
      mapRevision: state.trackerMapRevision,
      broadcasting: state.trackerBroadcasting === true,
      refreshMs: state.trackerTickMs,
      staleAfterMs: state.trackerStaleAfterMs,
    };
    return units;
  }

  function trackerListSignature(units) {
    if (trackerMath) return trackerMath.listSignature(units);
    return (units || []).map((unit) => `${unit.id}:${unit.plate}:${unit.status}`).sort().join('|');
  }

  function bindUnitButtons(root) {
    if (!root) return;
    root.querySelectorAll('[data-unit-plate]').forEach((button) => button.addEventListener('click', () => {
      state.selectedUnitPlate = button.dataset.unitPlate;
      state.selectedDispatchCallId = null;
      const unit = (state.trackerSnapshot?.units || []).find((item) => String(item.plate || '') === String(button.dataset.unitPlate || ''));
      if (unit && operationalMapReady) window.MZNavMap?.centerOnWorld(unit, 4);
      patchOperationalPanels();
    }));
    root.querySelector('#toggle-tracker')?.addEventListener('click', async () => {
      const target = state.trackerSnapshot?.broadcasting !== true;
      if (state.trackerV2) state.trackerBroadcasting = target;
      const response = await request('trackerBroadcast', { active: target });
      if (!response.ok) {
        if (state.trackerV2) state.trackerBroadcasting = !target;
        toast(messageFor(response), 'error');
        return;
      }
      if (!state.trackerV2) await loadTrackerSnapshot();
      syncUnitsPanel();
    });
  }

  function updateUnitText(root, units) {
    if (!root) return;
    root.querySelectorAll('[data-unit-id]').forEach((button) => {
      const unit = units.find((item) => item.id === button.dataset.unitId
        || String(item.plate || '') === String(button.dataset.unitPlate || ''));
      if (!unit) return;
      const small = button.querySelector('small');
      if (small) {
        const x = Number(unit.x);
        const y = Number(unit.y);
        small.textContent = Number.isFinite(x) && Number.isFinite(y)
          ? `X ${x.toFixed(0)} · Y ${y.toFixed(0)}` : 'Coordenadas indisponíveis';
      }
      const stateNode = button.querySelector('.tracker-unit__state');
      if (stateNode) {
        stateNode.textContent = unit.status === 'stale' ? 'ATRASADO'
          : unit.status === 'offduty' ? 'FORA DE SERVIÇO' : 'SINAL ATIVO';
      }
      button.classList.toggle('is-stale', unit.status === 'stale');
    });
  }

  function updateSelectedUnitDetail(units) {
    if (state.active !== 'operations') return;
    const detail = document.getElementById('operational-detail');
    if (!detail) return;
    const selected = units.find((item) => String(item.plate || '') === String(state.selectedUnitPlate || ''));
    if (!selected) {
      if (state.selectedUnitPlate) {
        state.selectedUnitPlate = null;
        detail.innerHTML = renderOperationalDetail();
        icons();
      }
      return;
    }
    const coords = detail.querySelector('[data-unit-coords]');
    if (coords) coords.textContent = `X ${Number(selected.x).toFixed(1)} · Y ${Number(selected.y).toFixed(1)}`;
  }

  function syncUnitsPanel() {
    const units = syncTrackerSnapshot();
    if (state.active === 'home') {
      const signature = trackerListSignature(units);
      if (signature !== state.trackerHomeSignature) {
        state.trackerHomeSignature = signature;
        render();
      }
      return;
    }
    if (state.active !== 'operations') return;
    const container = document.getElementById('operational-units');
    if (!container) return;
    const signature = trackerListSignature(units);
    if (signature !== state.trackerListSignature) {
      state.trackerListSignature = signature;
      container.innerHTML = renderUnitsList();
      bindUnitButtons(container);
      icons();
    } else {
      updateUnitText(container, units);
    }
    updateSelectedUnitDetail(units);
  }

  function stopPoliceAnimation() {
    if (state.trackerRaf) window.cancelAnimationFrame(state.trackerRaf);
    state.trackerRaf = null;
    state.trackerFrameAt = 0;
    state.trackerPanelAt = 0;
  }

  function startPoliceAnimation() {
    if (!state.trackerV2 || state.active !== 'operations' || state.trackerRaf || state.trackerUnits.size === 0) return;
    const frame = () => {
      state.trackerRaf = null;
      if (!state.open || state.active !== 'operations' || !state.trackerV2) return;
      const now = performance.now();
      const frameUnits = [];
      for (const unit of state.trackerUnits.values()) {
        const sampled = trackerMath
          ? trackerMath.sample(unit, now, state.trackerStaleAfterMs)
          : { x: unit.toX, y: unit.toY, z: unit.toZ, heading: unit.toHeading, status: unit.status };
        frameUnits.push({
          ...unit,
          x: sampled.x,
          y: sampled.y,
          z: sampled.z,
          heading: sampled.heading,
          status: sampled.status,
        });
      }
      if (now - state.trackerFrameAt >= 33) {
        window.MZNavMap?.updatePoliceMarkers(frameUnits);
        state.trackerFrameAt = now;
      }
      if (now - state.trackerPanelAt >= 500) {
        const units = syncTrackerSnapshot();
        updateUnitText(document.getElementById('operational-units'), units);
        updateSelectedUnitDetail(units);
        state.trackerPanelAt = now;
      }
      if (state.trackerUnits.size > 0) state.trackerRaf = window.requestAnimationFrame(frame);
    };
    state.trackerRaf = window.requestAnimationFrame(frame);
  }

  function poisSignature(layers, pois) {
    let hash = 0;
    const add = (text) => {
      const value = String(text ?? '');
      for (let index = 0; index < value.length; index += 1) {
        hash = (hash * 31 + value.charCodeAt(index)) % 2147483647;
      }
    };
    (layers || []).forEach((layer) => { add(layer.id); add(layer.revision); });
    (pois || []).forEach((poi) => {
      add(poi.id); add(poi.revision); add(poi.x); add(poi.y); add(poi.label);
    });
    return hash;
  }

  function handleTrackerDelta(message) {
    if (!state.trackerV2 || !state.open) return;
    if (!message || message.version !== 1 || message.layer !== 'police-units') return;
    const generation = Number(message.generation);
    const seq = Number(message.seq);
    if (!Number.isSafeInteger(generation) || !Number.isSafeInteger(seq)) return;
    if (state.trackerGeneration >= 0 && generation < state.trackerGeneration) return;
    if (generation !== state.trackerGeneration) {
      state.trackerGeneration = generation;
      state.trackerSeq = -1;
      state.trackerUnits.clear();
      state.trackerListSignature = '';
      state.trackerHomeSignature = '';
      window.MZNavMap?.clearPoliceMarkers?.();
    }
    if (seq <= state.trackerSeq) return;
    state.trackerSeq = seq;
    state.trackerLastDeltaAt = performance.now();
    state.trackerTickMs = Math.max(250, Math.min(10000, Number(message.tickMs) || state.trackerTickMs));
    state.trackerStaleAfterMs = Math.max(1000, Math.min(60000, Number(message.staleAfterMs) || state.trackerStaleAfterMs));
    state.trackerTeleportThreshold = Math.max(10, Number(message.teleportThreshold) || state.trackerTeleportThreshold);

    const now = performance.now();
    const removed = Array.isArray(message.removedIds) ? message.removedIds : [];
    for (const id of removed) {
      if (typeof id === 'string') state.trackerUnits.delete(id);
    }
    if (removed.length) window.MZNavMap?.applyPoliceDelta?.([], removed);

    const upserts = Array.isArray(message.upserts) ? message.upserts : [];
    for (const raw of upserts) {
      const unit = trackerMath ? trackerMath.normalizeUnit(raw) : raw;
      if (!unit) continue;
      const existing = state.trackerUnits.get(unit.id);
      const next = trackerMath ? trackerMath.makeState(existing, unit, now, {
        tickMs: state.trackerTickMs,
        staleAfterMs: state.trackerStaleAfterMs,
        teleportThreshold: state.trackerTeleportThreshold,
      }) : unit;
      if (next) state.trackerUnits.set(unit.id, next);
    }

    const alive = Array.isArray(message.aliveIds) ? message.aliveIds : [];
    for (const id of alive) {
      if (typeof id === 'string' && state.trackerUnits.has(id) && trackerMath) {
        trackerMath.markSeen(state.trackerUnits.get(id), now);
      }
    }

    state.trackerBroadcasting = message.broadcasting === true;
    if (message.map) {
      state.trackerMap = message.map;
      state.trackerMapRevision = message.mapRevision;
      state.mapPoisSignature = '';
      if (state.active === 'operations') updateOperationalMap();
    }

    syncUnitsPanel();
    if (state.active === 'operations') startPoliceAnimation();
  }

  function handleTrackerReset(message) {
    if (!state.trackerV2) return;
    const reason = String(message?.reason || 'reset');
    stopPoliceAnimation();
    state.trackerUnits.clear();
    state.trackerBroadcasting = false;
    state.trackerListSignature = '';
    state.trackerHomeSignature = '';
    window.MZNavMap?.clearPoliceMarkers?.();
    const passive = ['unsubscribed', 'stopped', 'resource_stop', 'connecting'].includes(reason);
    if (!passive) {
      state.trackerMap = null;
      state.trackerMapRevision = null;
      state.mapPoisSignature = '';
      syncOperationalMapLayers();
    }
    state.trackerSnapshot = passive ? null : {
      ok: false,
      code: reason,
      units: [],
      map: state.trackerMap,
      refreshMs: state.trackerTickMs,
      staleAfterMs: state.trackerStaleAfterMs,
    };
    if (state.active === 'operations') {
      const container = document.getElementById('operational-units');
      if (container) {
        container.innerHTML = renderUnitsList();
        bindUnitButtons(container);
        icons();
      }
    } else if (state.active === 'home') {
      render();
    }
  }

  function refreshTrackerView() {
    if (state.trackerV2) {
      request('trackerSetView', { active: state.active === 'home' || state.active === 'operations' });
    } else if (state.active === 'home' || state.active === 'operations') {
      loadTrackerSnapshot();
    }
  }

  function renderOperationalDetail() {
    const call = (state.dispatch?.items || []).find((item) => String(value(item, 'public_id', 'publicId')) === String(state.selectedDispatchCallId || ''));
    if (call) {
      return `<span class="kicker">CHAMADO SELECIONADO</span><h3>${esc(call.message || 'Chamado')}</h3><p>${esc(dispatchLocation(call))}</p><div class="operational-detail__actions"><button class="button" type="button" data-dispatch-waypoint="${esc(value(call, 'public_id', 'publicId'))}"><i data-lucide="map-pin"></i>Marcar rota</button><button class="button" type="button" data-dispatch-accept="${esc(value(call, 'public_id', 'publicId'))}"><i data-lucide="radio"></i>Aceitar</button></div>`;
    }
    const unit = (state.trackerSnapshot?.units || []).find((item) => String(item.plate || '') === String(state.selectedUnitPlate || ''));
    if (unit) {
      const coords = unit.coordinates || unit;
      return `<span class="kicker">UNIDADE SELECIONADA</span><h3>${esc(unit.plate || 'Viatura')}</h3><p data-unit-coords>X ${esc(Number(coords.x).toFixed(1))} · Y ${esc(Number(coords.y).toFixed(1))}</p><button id="center-operational-selection" class="button" type="button"><i data-lucide="crosshair"></i>Centralizar</button>`;
    }
    return `<span class="kicker">DETALHES</span><h3>Nenhum marcador selecionado</h3><p>Selecione um chamado, uma viatura ou um ponto permitido no mapa.</p>`;
  }

  function renderOperations() {
    const snapshot = state.trackerSnapshot;
    const loading = state.loading.has('trackerSnapshot');
    const refreshLabel = loading ? 'ATUALIZANDO' : snapshot?.ok ? `${Math.round((snapshot.refreshMs || 3000) / 1000)}S` : 'AGUARDANDO';
    return `<div class="operational-shell">
      <section class="operational-map-panel panel">
        <div class="panel-header"><div><h2>Central operacional</h2><p>Cartografia, chamados e transmissões autorizadas em uma única superfície.</p></div><span id="operational-refresh" class="tracker-live"><i aria-hidden="true"></i>${refreshLabel}</span></div>
        <div class="operational-map-wrap">
          <svg id="operational-map" class="nav-map operational-map" viewBox="0 0 1000 1000" role="application" aria-label="Mapa operacional interativo" preserveAspectRatio="xMidYMid slice">
            <defs><radialGradient id="navGlow" cx="50%" cy="45%" r="62%"><stop offset="0%" stop-color="#1b2432"></stop><stop offset="100%" stop-color="#0d1118"></stop></radialGradient></defs>
            <rect x="-100" y="-100" width="1200" height="1200" fill="url(#navGlow)"></rect>
            <g id="navBaseMap"></g><g id="navTiles"></g><g id="navRegions"></g><g id="navGrid"></g><g id="navDistricts"></g><g id="navNativeBlips"></g><g id="navExternalMarkers"></g><g id="navPoliceLayer"></g><g id="navPois"></g><g id="navRoute"></g><g id="navCandidate"></g>
          </svg>
          <div class="nav-map-tools operational-map-tools"><button type="button" data-operational-zoom="in" aria-label="Aproximar">+</button><button type="button" data-operational-zoom="out" aria-label="Afastar">−</button><button type="button" id="fit-operational-map" aria-label="Ajustar à área">◎</button></div>
          <div class="operational-map-filters" aria-label="Camadas do mapa">
            ${[['dispatch', 'Chamados'], ['units', 'Viaturas'], ['pois', 'Pontos']].map(([id, label]) => `<label><input type="checkbox" name="operational-layer" value="${id}" data-map-layer="${id}"${state.operationalLayers.has(id) ? ' checked' : ''}>${label}</label>`).join('')}
          </div>
          ${snapshot?.map ? '' : `<div id="operational-map-state" class="operational-map-state" role="status"><i data-lucide="${loading ? 'loader-circle' : 'map'}"></i><strong>${loading ? 'Carregando cartografia' : 'Cartografia indisponível'}</strong><span>Consultas e casos continuam disponíveis.</span></div>`}
        </div>
      </section>
      <aside class="operational-side stack">
        <section class="panel"><div class="panel-body operational-actions"><button id="dispatch-panic" class="button button--panic" type="button"><i data-lucide="radio"></i>Alerta de pânico</button><span>Use somente em emergência imediata.</span></div></section>
        <section id="operational-detail" class="panel panel-body operational-detail">${renderOperationalDetail()}</section>
      </aside>
      <section id="operational-queue" class="panel operational-queue">${renderDispatchQueue()}</section>
      <section id="operational-units" class="panel operational-units">${renderUnitsList()}</section>
    </div>`;
  }

  async function updateOperationalMap() {
    if (!state.open || state.active !== 'operations') return;
    const svg = document.getElementById('operational-map');
    const data = operationalMapData();
    if (!svg || !data.map) return;
    const map = await ensureNavigationEngine();
    if (!map || svg !== document.getElementById('operational-map')) return;
    let wasReady = operationalMapReady;
    if (!operationalMapReady) {
      const preservedCamera = state.operationalCamera;
      map.destroy?.();
      map.init(svg, {
        onCamera: (camera) => { state.operationalCamera = camera; },
        onSelect: (_, poi) => {
          if (poi?.kind === 'dispatch') {
            state.selectedDispatchCallId = poi.id.replace(/^dispatch:/, '');
            state.selectedUnitPlate = null;
            patchOperationalPanels();
          } else if (poi?.kind === 'unit') {
            state.selectedUnitPlate = poi.plate;
            state.selectedDispatchCallId = null;
            patchOperationalPanels();
          }
        },
        onPoliceSelect: (unitId) => {
          const unit = (state.trackerSnapshot?.units || []).find((item) => item.id === unitId
            || String(item.plate || '') === String(unitId || ''));
          if (!unit) return;
          state.selectedUnitPlate = unit.plate;
          state.selectedDispatchCallId = null;
          syncUnitsPanel();
        },
      });
      map.configure({ ...data.map, assetBase: navigationAssetBase });
      if (preservedCamera) map.setCamera(preservedCamera);
      map.setPoliceVisible(state.operationalLayers.has('units'));
      operationalMapReady = true;
      wasReady = false;
    }

    const signature = poisSignature(data.layers, data.pois);
    if (!wasReady || signature !== state.mapPoisSignature) {
      map.setData(data.pois, data.layers);
      state.mapPoisSignature = signature;
    }
    map.setVisibleLayers(data.visible);
    map.setPoliceVisible(state.operationalLayers.has('units'));
    if (!wasReady) {
      map.setPoliceUnits([...state.trackerUnits.values()]);
      startPoliceAnimation();
    }
  }

  function patchOperationalPanels() {
    if (state.active !== 'operations') return;
    const queue = document.getElementById('operational-queue');
    const units = document.getElementById('operational-units');
    const detail = document.getElementById('operational-detail');
    const mapState = document.getElementById('operational-map-state');
    const refresh = document.getElementById('operational-refresh');
    if (queue) queue.innerHTML = renderDispatchQueue();
    if (units) {
      if (state.trackerV2) syncTrackerSnapshot();
      units.innerHTML = renderUnitsList();
      state.trackerListSignature = state.trackerV2
        ? trackerListSignature(state.trackerSnapshot?.units || []) : '';
    }
    if (detail) detail.innerHTML = renderOperationalDetail();
    if (state.trackerSnapshot?.map) mapState?.remove();
    if (refresh) refresh.innerHTML = `<i aria-hidden="true"></i>${state.loading.has('trackerSnapshot') ? 'ATUALIZANDO' : state.trackerSnapshot?.ok ? `${Math.round((state.trackerSnapshot.refreshMs || (state.trackerV2 ? state.trackerTickMs : 3000)) / 1000)}S` : 'AGUARDANDO'}`;
    bindOperationalContent();
    icons();
    updateOperationalMap();
  }

  const renders = {
    home: renderDashboard, citizens: renderCitizens, profile: renderProfile, cases: renderCases,
    vehicles: renderVehicles,
    charges: renderCharges, citations: renderCitations, warrants: renderWarrants,
    evidence: renderEvidence, history: renderHistory,
  };

  function renderViewNavigation() {
    const views = sectionViews[state.active];
    if (!views) return '';
    return `<nav class="view-navigation" aria-label="Navegação contextual">${views.map(([id, label]) => `<button class="view-navigation__button${state.view === id ? ' is-active' : ''}" type="button" data-view="${id}" aria-current="${state.view === id ? 'page' : 'false'}">${label}</button>`).join('')}</nav>`;
  }

  function renderNavigation() {
    navigation.innerHTML = sections.map(([id, label, icon]) => `<button class="nav-button ${state.active === id ? 'is-active' : ''}" type="button" data-section="${id}" aria-label="${label}" title="${label}" aria-current="${state.active === id ? 'page' : 'false'}"><i data-lucide="${icon}" aria-hidden="true"></i><span>${label}</span></button>`).join('');
  }

  function render() {
    if (state.active !== 'operations') {
      stopPoliceAnimation();
      if (operationalMapReady) window.MZNavMap?.destroy?.();
      operationalMapReady = false;
    }
    if (state.active !== 'operations' && state.active !== 'home') clearTrackerRefresh();
    if (state.trackerV2) syncTrackerSnapshot();
    const meta = sections.find(([id]) => id === state.active) || sections[0];
    title.textContent = meta[1];
    kicker.textContent = meta[3];
    content.className = `content ${state.active === 'operations' || (state.active === 'cases' && state.view === 'cases') || (state.active === 'consultations' && state.view === 'citizens') ? 'is-contained' : 'is-page-scroll'}`;
    renderNavigation();
    content.innerHTML = state.active === 'operations'
      ? renderOperations()
      : `${renderViewNavigation()}${(renders[state.view] || renderDashboard)()}`;
    bindContent();
    icons();
    if (state.active === 'operations') {
      state.trackerListSignature = trackerListSignature(state.trackerSnapshot?.units || []);
      updateOperationalMap();
      startPoliceAnimation();
    }
  }

  function messageFor(response) {
    return codeLabels[response?.code] || `Operação recusada: ${response?.code || 'erro desconhecido'}.`;
  }

  async function loadCases(renderView = true) {
    const response = await request('listCases', { page: 1, pageSize: 25 });
    if (response.ok) { state.cases = response.items || []; markUpdated('cases'); }
    else toast(messageFor(response), 'error');
    if (renderView) render();
  }

  async function loadCase(caseId) {
    const response = await request('getCase', { caseId });
    if (!response.ok) { toast(messageFor(response), 'error'); return; }
    state.selectedCase = response.case;
    markUpdated('case');
    routeTo('cases');
    render();
  }

  async function loadArrestPreview() {
    if (!state.processing || !state.targetSource) return;
    const response = await request('arrestPreview', { targetSource: state.targetSource });
    if (!response.ok) { toast(messageFor(response), 'error'); return; }
    state.arrestPreview = response;
    render();
  }

  async function loadCitizen(citizenid) {
    const response = await request('getCitizen', { citizenid });
    if (!response.ok) { toast(messageFor(response), 'error'); return; }
    state.selectedCitizen = response;
    markUpdated('citizen');
    state.targetSource = null;
    state.sentence = null;
    routeTo('profile');
    render();
  }

  async function loadVehicle(plate) {
    const response = await request('lookupVehicle', { plate });
    if (!response.ok) { state.selectedVehicle = null; toast(messageFor(response), 'error'); render(); return; }
    state.selectedVehicle = response;
    markUpdated('vehicle');
    render();
  }

  let dispatchReloadQueued = false;

  function clearTrackerRefresh() {
    if (trackerRefreshTimer !== null) {
      window.clearTimeout(trackerRefreshTimer);
      trackerRefreshTimer = null;
    }
  }

  async function loadTrackerSnapshot() {
    if (state.trackerV2) return;
    if (!state.open || (state.active !== 'operations' && state.active !== 'home') || state.loading.has('trackerSnapshot')) return;
    clearTrackerRefresh();
    const pending = request('trackerSnapshot', {});
    patchOperationalPanels();
    const response = await pending;
    state.trackerSnapshot = response;
    if (response.ok) markUpdated('units');
    if (!response.ok) {
      syncOperationalMapLayers();
      toast(messageFor(response), 'error');
    }
    if (!state.open || (state.active !== 'operations' && state.active !== 'home')) return;
    if (state.active === 'operations') patchOperationalPanels(); else render();
    if (response.ok) {
      const delay = Math.max(2000, Math.min(10000, Number(response.refreshMs) || 3000));
      trackerRefreshTimer = window.setTimeout(loadTrackerSnapshot, delay);
    }
  }

  async function loadDispatch() {
    // Snapshot em andamento: nao reenviar consulta (o cliente Lua recusaria com
    // operation_busy) nem duplicar toasts de erro. Uma invalidacao que chegue
    // durante a consulta agenda uma unica reconsulta apos a resposta atual.
    if (state.loading.has('dispatchList')) { dispatchReloadQueued = true; return; }
    dispatchReloadQueued = false;
    const response = await request('dispatchList', { serviceCode: 'police', page: 1, pageSize: 25 });
    if (response.ok) { state.dispatch = response; markUpdated('dispatch'); } else toast(messageFor(response), 'error');
    if (state.active === 'operations') patchOperationalPanels(); else render();
    if (dispatchReloadQueued) loadDispatch();
  }

  function clearDataRefresh() {
    if (dataRefreshTimer !== null) window.clearTimeout(dataRefreshTimer);
    dataRefreshTimer = null;
  }

  function scheduleDataRefresh() {
    clearDataRefresh();
    if (!state.open || preview) return;
    dataRefreshTimer = window.setTimeout(refreshPassiveData, 15000);
  }

  async function refreshPassiveData() {
    dataRefreshTimer = null;
    if (!state.open) return;
    const canReplaceView = !state.dirty && !content.matches(':focus-within');
    try {
      if ((state.active === 'home' || state.active === 'cases') && !state.loading.has('listCases')) {
        const response = await request('listCases', { page: 1, pageSize: 25 });
        if (response.ok) { state.cases = response.items || []; markUpdated('cases'); }
      }
      if (state.active === 'cases' && state.selectedCase && canReplaceView && !state.loading.has('getCase')) {
        const response = await request('getCase', { caseId: value(state.selectedCase, 'public_id', 'publicId') });
        if (response.ok) { state.selectedCase = response.case; markUpdated('case'); }
      }
      if (state.active === 'consultations' && state.selectedCitizen && canReplaceView && !state.loading.has('getCitizen')) {
        const response = await request('getCitizen', { citizenid: state.selectedCitizen.citizen?.citizenid });
        if (response.ok) { state.selectedCitizen = response; markUpdated('citizen'); }
      } else if (state.active === 'consultations' && state.view === 'citizens' && state.citizenQuery && !state.loading.has('searchCitizens')) {
        const response = await request('searchCitizens', { query: state.citizenQuery, page: 1, pageSize: 25 });
        if (response.ok) { state.citizenSearch = response.result; markUpdated('citizens'); }
      }
      if (state.active === 'vehicles' && state.vehicleQuery && !state.loading.has('lookupVehicle')) {
        const response = await request('lookupVehicle', { plate: state.vehicleQuery });
        if (response.ok) { state.selectedVehicle = response; markUpdated('vehicle'); }
      }
      if ((state.active === 'home' || state.active === 'operations') && !state.loading.has('dispatchList')) await loadDispatch();
      if (canReplaceView && state.active !== 'operations' && (state.active !== 'cases' || state.selectedCase)) render();
    } finally {
      scheduleDataRefresh();
    }
  }

  function bindOperationalContent() {
    content.querySelectorAll('[data-select-call]').forEach((button) => button.addEventListener('click', () => {
      state.selectedDispatchCallId = button.dataset.selectCall;
      state.selectedUnitPlate = null;
      const call = (state.dispatch?.items || []).find((item) => String(value(item, 'public_id', 'publicId')) === button.dataset.selectCall);
      if (call && operationalMapReady) {
        window.MZNavMap.centerOnWorld({ x: value(call, 'location_x', 'locationX'), y: value(call, 'location_y', 'locationY') }, 4);
      }
      patchOperationalPanels();
    }));
    content.querySelectorAll('[data-unit-plate]').forEach((button) => button.addEventListener('click', () => {
      state.selectedUnitPlate = button.dataset.unitPlate;
      state.selectedDispatchCallId = null;
      const unit = (state.trackerSnapshot?.units || []).find((item) => String(item.plate || '') === button.dataset.unitPlate);
      if (unit && operationalMapReady) window.MZNavMap.centerOnWorld(unit.coordinates, 4);
      patchOperationalPanels();
    }));
    content.querySelectorAll('[data-map-layer]').forEach((input) => input.addEventListener('change', () => {
      if (input.checked) state.operationalLayers.add(input.dataset.mapLayer);
      else state.operationalLayers.delete(input.dataset.mapLayer);
      updateOperationalMap();
    }));
    content.querySelectorAll('[data-operational-zoom]').forEach((button) => button.addEventListener('click', () => {
      window.MZNavMap?.zoomBy(button.dataset.operationalZoom === 'in' ? 0.5 : -0.5);
    }));
    document.getElementById('fit-operational-map')?.addEventListener('click', () => {
      const data = operationalMapData();
      window.MZNavMap?.fitPoints(data.pois.filter((poi) => data.visible.has(poi.layer)));
    });
    document.getElementById('center-operational-selection')?.addEventListener('click', () => {
      const unit = (state.trackerSnapshot?.units || []).find((item) => String(item.plate || '') === String(state.selectedUnitPlate || ''));
      if (unit) window.MZNavMap?.centerOnWorld(unit.coordinates, 4);
    });
    document.getElementById('reload-dispatch')?.addEventListener('click', loadDispatch);
    document.getElementById('toggle-tracker')?.addEventListener('click', async () => {
      const response = await request('trackerBroadcast', { active: state.trackerSnapshot?.broadcasting !== true });
      if (!response.ok) { toast(messageFor(response), 'error'); return; }
      await loadTrackerSnapshot();
    });
    content.querySelectorAll('[data-dispatch-waypoint]').forEach((button) => button.addEventListener('click', async () => {
      const call = (state.dispatch?.items || []).find((item) => String(value(item, 'public_id', 'publicId')) === button.dataset.dispatchWaypoint);
      const response = await request('dispatchWaypoint', {
        x: value(call, 'location_x', 'locationX'), y: value(call, 'location_y', 'locationY'), z: value(call, 'location_z', 'locationZ'),
      });
      if (!response.ok) { toast(messageFor(response), 'error'); return; }
      toast('Destino do chamado marcado no GPS.');
    }));
    document.getElementById('dispatch-panic')?.addEventListener('click', async (event) => {
      const button = event.currentTarget;
      const confirmed = await confirmAction({
        title: 'Enviar alerta de pânico?',
        message: 'A central policial receberá um chamado urgente com sua localização atual.',
        confirmLabel: 'Enviar alerta',
      });
      if (!confirmed) return;
      button.disabled = true;
      try {
        const response = await request('dispatchPanic', {});
        if (!response.ok) { toast(messageFor(response), 'error'); return; }
        toast('Alerta de pânico enviado à fila policial.');
        await loadDispatch();
      } finally {
        if (button.isConnected) button.disabled = false;
      }
    });
    content.querySelectorAll('[data-dispatch-accept]').forEach((button) => button.addEventListener('click', async () => {
      const response = await request('dispatchAccept', { callId: button.dataset.dispatchAccept });
      if (!response.ok) { toast(messageFor(response), 'error'); return; }
      toast('Chamado aceito. O local foi marcado temporariamente.');
      await loadDispatch();
    }));
    content.querySelectorAll('[data-dispatch-close]').forEach((button) => button.addEventListener('click', async () => {
      const confirmed = await confirmAction({
        title: 'Encerrar chamado?', message: 'O encerramento será registrado pela central.', confirmLabel: 'Encerrar',
      });
      if (!confirmed) return;
      const response = await request('dispatchClose', { callId: button.dataset.dispatchClose });
      if (!response.ok) { toast(messageFor(response), 'error'); return; }
      toast('Chamado encerrado.');
      await loadDispatch();
    }));
  }

  function bindContent() {
    content.querySelectorAll('[data-go]').forEach((button) => button.addEventListener('click', () => { routeTo(button.dataset.go); render(); }));
    content.querySelectorAll('[data-case-id]').forEach((button) => button.addEventListener('click', () => loadCase(button.dataset.caseId)));
    content.querySelectorAll('[data-citizen-id]').forEach((button) => button.addEventListener('click', () => loadCitizen(button.dataset.citizenId)));
    content.querySelectorAll('[data-view]').forEach((button) => button.addEventListener('click', () => { routeTo(button.dataset.view); render(); }));

    document.getElementById('reload-cases')?.addEventListener('click', loadCases);
    document.getElementById('case-filter-kind')?.addEventListener('change', (event) => { state.caseFilter.kind = event.target.value; render(); });
    document.getElementById('case-filter-period')?.addEventListener('change', (event) => { state.caseFilter.period = event.target.value; render(); });
    content.querySelector('[data-case-step="next"]')?.addEventListener('click', () => {
      const titleField = document.getElementById('case-title');
      if (!titleField?.reportValidity()) return;
      content.querySelector('[data-case-step-panel="1"]').hidden = true;
      content.querySelector('[data-case-step-panel="2"]').hidden = false;
      content.querySelector('[data-case-step="next"]').hidden = true;
      content.querySelector('[data-case-step="back"]').hidden = false;
      content.querySelector('[data-case-step="submit"]').hidden = false;
      document.getElementById('case-step-label').textContent = '2';
      document.getElementById('case-summary')?.focus();
    });
    content.querySelector('[data-case-step="back"]')?.addEventListener('click', () => {
      content.querySelector('[data-case-step-panel="1"]').hidden = false;
      content.querySelector('[data-case-step-panel="2"]').hidden = true;
      content.querySelector('[data-case-step="next"]').hidden = false;
      content.querySelector('[data-case-step="back"]').hidden = true;
      content.querySelector('[data-case-step="submit"]').hidden = true;
      document.getElementById('case-step-label').textContent = '1';
      document.getElementById('case-title')?.focus();
    });
    bindOperationalContent();
    content.querySelectorAll('[data-request-citation-payment]').forEach((button) => button.addEventListener('click', async () => {
      const confirmed = await confirmAction({
        title: 'Solicitar pagamento?',
        message: 'Uma solicitação será enviada ao cidadão próximo. Ele ainda precisará autorizar o pagamento.',
        confirmLabel: 'Enviar solicitação',
      });
      if (!confirmed) return;
      button.disabled = true;
      try {
        const response = await request('requestCitationPayment', {
          targetSource: state.targetSource,
          citationId: button.dataset.requestCitationPayment,
          requestId: requestId('citation_request'),
        });
        if (!response.ok) { toast(messageFor(response), 'error'); return; }
        toast('Solicitação enviada. O cidadão decide se autoriza o débito.');
      } finally {
        button.disabled = false;
      }
    }));
    document.getElementById('new-case')?.addEventListener('click', () => { state.selectedCase = null; render(); });
    document.getElementById('load-evidence')?.addEventListener('click', async () => {
      const response = await request('evidenceList', { containerId: 'intake' });
      if (response.ok) state.evidence = response; else toast(messageFor(response), 'error');
      render();
    });
    content.querySelectorAll('[data-evidence-link]').forEach((button) => button.addEventListener('click', async () => {
      const response = await request('evidenceLink', {
        caseId: value(state.selectedCase, 'public_id', 'publicId'),
        containerId: state.evidence.containerId,
        instanceUid: button.dataset.evidenceLink,
        requestId: requestId('evidence_link'),
      });
      if (!response.ok) { toast(messageFor(response), 'error'); return; }
      state.selectedCase = response.case;
      toast('Evidência vinculada ao caso.');
      render();
    }));
    content.querySelectorAll('[data-forensic-analyze]').forEach((button) => button.addEventListener('click', async () => {
      const response = await request('forensicAnalyze', {
        caseId: value(state.selectedCase, 'public_id', 'publicId'),
        instanceUid: button.dataset.forensicAnalyze,
        method: 'weapon_identity',
      });
      if (!response.ok) { toast(messageFor(response), 'error'); return; }
      state.selectedCase = response.case;
      toast('Identificação da arma registrada a partir do serial canônico.');
      render();
    }));

    document.getElementById('load-sentence')?.addEventListener('click', async () => {
      const citizenid = state.selectedCitizen?.citizen?.citizenid;
      if (!citizenid) return;
      const response = await request('getSentence', { citizenid });
      if (response.ok) state.sentence = response; else toast(messageFor(response), 'error');
      render();
    });

    document.getElementById('load-legal-catalog')?.addEventListener('click', async () => {
      const response = await request('getLegalCatalog', {});
      if (response.ok) state.legalCatalog = response; else toast(messageFor(response), 'error');
      render();
    });

    document.getElementById('charge-form')?.addEventListener('submit', async (event) => {
      event.preventDefault();
      const response = await request('addCaseCharge', {
        caseId: value(state.selectedCase, 'public_id', 'publicId'),
        citizenid: state.selectedCitizen.citizen.citizenid,
        ruleCode: document.getElementById('charge-rule').value,
        requestId: requestId('charge'),
      });
      if (!response.ok) { toast(messageFor(response), 'error'); return; }
      toast('Acusação adicionada com valores definidos pelo servidor.');
      await loadCase(value(state.selectedCase, 'public_id', 'publicId'));
      routeTo('charges');
      render();
    });

    document.getElementById('arrest-processing-form')?.addEventListener('submit', async (event) => {
      event.preventDefault();
      const selected = [...content.querySelectorAll('input[name="arrest-rule"]:checked')].map((input) => input.value);
      const maximum = Number(state.arrestPreview?.limits?.maxCharges || 1);
      if (!selected.length || selected.length > maximum) { toast('Selecione uma quantidade válida de acusações.', 'error'); return; }
      state.arrestReport = document.getElementById('arrest-report').value;
      const response = await request('arrestQuote', { targetSource: state.targetSource, ruleCodes: selected });
      if (!response.ok) { toast(messageFor(response), 'error'); return; }
      state.arrestQuote = response;
      state.dirty = false;
      render();
    });

    document.getElementById('confirm-arrest-processing')?.addEventListener('click', async () => {
      const response = await request('arrestCommit', {
        targetSource: state.targetSource,
        ruleCodes: (state.arrestQuote?.charges || []).map((charge) => charge.code),
        notes: state.arrestReport,
        expectedCustodyRevision: Number(state.arrestPreview?.custody?.revision || 0),
      });
      if (!response.ok) { toast(messageFor(response), 'error'); return; }
      state.arrestCommitted = response;
      state.dirty = false;
      const caseResponse = await request('getCase', { caseId: response.caseId });
      if (caseResponse.ok) state.selectedCase = caseResponse.case;
      toast('Processamento confirmado. Intake prisional preparado.');
      routeTo('charges');
      render();
    });

    content.querySelectorAll('[data-prepare-intake]').forEach((button) => button.addEventListener('click', async () => {
      const response = await request('prepareIntake', {
        targetSource: state.targetSource,
        citizenid: state.selectedCitizen.citizen.citizenid,
        caseId: value(state.selectedCase, 'public_id', 'publicId'),
        chargeId: button.dataset.prepareIntake,
      });
      if (!response.ok) { toast(messageFor(response), 'error'); return; }
      toast('Encaminhamento preparado. Leve o custodiado ao intake e use a interação do local.');
    }));

    document.getElementById('citizen-search-form')?.addEventListener('submit', async (event) => {
      event.preventDefault();
      const query = document.getElementById('citizen-query').value.trim();
      if (query.length < 2) { toast('Informe pelo menos dois caracteres.', 'error'); return; }
      state.citizenQuery = query;
      const response = await request('searchCitizens', { query, page: 1, pageSize: 25 });
      if (response.ok) { state.citizenSearch = response.result; markUpdated('citizens'); } else toast(messageFor(response), 'error');
      render();
    });

    document.getElementById('vehicle-search-form')?.addEventListener('submit', async (event) => {
      event.preventDefault();
      const plate = document.getElementById('vehicle-query').value.trim().toUpperCase();
      if (plate.length < 2) { toast('Informe uma placa válida.', 'error'); return; }
      state.vehicleQuery = plate;
      await loadVehicle(plate);
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
      state.dirty = false;
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
      state.dirty = false;
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
      state.dirty = false;
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
      state.dirty = false;
      toast('Pessoa vinculada ao caso.');
      render();
    });
  }

  function open(bootstrap = {}) {
    state.open = true;
    routeTo('home');
    state.cases = bootstrap.items || [];
    state.selectedCase = null;
    state.legalCatalog = null;
    state.evidence = null;
    state.selectedCitizen = bootstrap.selectedCitizen || null;
    state.vehicleQuery = '';
    state.selectedVehicle = null;
    state.targetSource = Number(bootstrap.targetSource) || null;
    state.processing = bootstrap.processing || null;
    state.arrestPreview = null;
    state.arrestQuote = null;
    state.arrestReport = '';
    state.arrestCommitted = null;
    state.sentence = null;
    state.dispatch = null;
    state.trackerSnapshot = null;
    state.trackerV2 = bootstrap.trackerV2 === true;
    const trackerConfig = bootstrap.trackerV2Config || {};
    state.trackerTickMs = Math.max(250, Math.min(10000, Number(trackerConfig.tickMs) || 1000));
    state.trackerStaleAfterMs = Math.max(1000, Math.min(60000, Number(trackerConfig.staleAfterMs) || 5000));
    state.trackerTeleportThreshold = Math.max(10, Number(trackerConfig.teleportThreshold) || 250);
    state.trackerUnits.clear();
    state.trackerGeneration = -1;
    state.trackerSeq = -1;
    state.trackerMap = null;
    state.trackerMapRevision = null;
    state.trackerBroadcasting = false;
    state.trackerListSignature = '';
    state.trackerHomeSignature = '';
    state.mapPoisSignature = '';
    stopPoliceAnimation();
    state.selectedUnitPlate = null;
    state.selectedDispatchCallId = null;
    state.operationalCamera = null;
    state.updatedAt = {};
    app.classList.add('is-open');
    app.setAttribute('aria-hidden', 'false');
    previewBadge.hidden = !preview;
    markUpdated('cases');
    render();
    if (!preview) scheduleDataRefresh();
    if (state.processing) { routeTo('charges'); render(); loadArrestPreview(); }
    else if (!preview) { loadDispatch(); refreshTrackerView(); }
  }

  function close() {
    if (state.trackerV2) {
      post('request', {
        action: 'trackerSetView',
        requestId: requestId('trackerClose'),
        payload: { active: false },
      });
    }
    state.open = false;
    activeConfirmation?.cancel();
    clearTrackerRefresh();
    clearDataRefresh();
    stopPoliceAnimation();
    state.trackerUnits.clear();
    state.trackerSnapshot = null;
    state.trackerGeneration = -1;
    state.trackerSeq = -1;
    state.trackerListSignature = '';
    state.trackerHomeSignature = '';
    if (operationalMapReady) window.MZNavMap?.destroy?.();
    operationalMapReady = false;
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
    routeTo(button.dataset.section);
    render();
    if (state.active === 'operations' || state.active === 'home') {
      loadDispatch();
      refreshTrackerView();
    } else {
      refreshTrackerView();
    }
  });
  content.addEventListener('input', (event) => {
    if (event.target.closest('#case-create-form, #case-update-form, #case-person-form, #record-form, #arrest-processing-form')) state.dirty = true;
  });
  document.getElementById('close-button').addEventListener('click', requestClose);
  document.getElementById('refresh-button').addEventListener('click', () => {
    if (state.active === 'home') { loadCases(); loadDispatch(); refreshTrackerView(); }
    else if (state.active === 'operations') { loadDispatch(); refreshTrackerView(); }
    else if (state.active === 'cases') loadCases();
    else if (state.active === 'vehicles' && state.vehicleQuery) loadVehicle(state.vehicleQuery);
    else if (state.active === 'consultations' && state.selectedCitizen) loadCitizen(state.selectedCitizen.citizen?.citizenid);
    else render();
  });
  document.addEventListener('keydown', (event) => {
    if (event.key !== 'Escape') return;
    if (activePolicePanel) { closePolicePanel(true); return; }
    if (state.open) requestClose();
  });
  window.addEventListener('message', (event) => {
    const message = event.data || {};
    if (message.type === 'panel:open') { openPolicePanel(message.panel); return; }
    if (message.type === 'panel:close') { closePolicePanel(false); return; }
    if (message.type === 'mdt:open') { open(message.bootstrap || {}); return; }
    if (message.type === 'mdt:context') {
      state.selectedCitizen = message.selectedCitizen || null;
      state.targetSource = Number(message.targetSource) || null;
      state.processing = message.processing || null;
      state.arrestPreview = null;
      state.arrestQuote = null;
      state.arrestReport = '';
      state.arrestCommitted = null;
      state.sentence = null;
      routeTo(state.processing ? 'charges' : 'profile');
      render();
      if (state.processing) loadArrestPreview();
      return;
    }
    if (message.type === 'mdt:close') { close(); return; }
    if (message.type === 'mdt:tracker:delta') { handleTrackerDelta(message); return; }
    if (message.type === 'mdt:tracker:reset') { handleTrackerReset(message); return; }
    // Sinal de tempo real do owner: somente reconsulta a lista canonica.
    // Nunca exibe toast; o aviso de NOVO chamado pertence ao mz_notify.
    if (message.type === 'mdt:dispatch:refresh') {
      if (state.open && (state.active === 'operations' || state.active === 'home')) loadDispatch();
      return;
    }
    if (message.type === 'mdt:data:refresh') {
      if (!state.open) return;
      if ((message.scope === 'cases' || message.scope === 'all') && (state.active === 'cases' || state.active === 'home')) loadCases();
      else if ((message.scope === 'citizen' || message.scope === 'all') && state.selectedCitizen) loadCitizen(state.selectedCitizen.citizen?.citizenid);
      else if ((message.scope === 'vehicle' || message.scope === 'all') && state.vehicleQuery) loadVehicle(state.vehicleQuery);
      return;
    }
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
