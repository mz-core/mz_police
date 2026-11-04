/**
 * mz_police - matematica pura do Tracker V2 (sem DOM, sem natives).
 *
 * Usada pela NUI para interpolar posicao/heading entre amostras recebidas.
 * Nao extrapola: quando a amostra fica velha, congela no ultimo ponto e
 * marca `stale`.
 *
 * UMD minimo para teste com `node`.
 */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  } else {
    root.MZPoliceTrackerMath = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  const CATEGORIES = new Set(["car", "moto", "helicopter", "boat", "plane", "generic"]);
  const STATUSES = new Set(["active", "stale", "offduty"]);

  function finite(value) {
    return typeof value === "number" && Number.isFinite(value);
  }

  function clamp(value, minimum, maximum) {
    return Math.min(Math.max(value, minimum), maximum);
  }

  function clamp01(value) {
    return clamp(Number(value) || 0, 0, 1);
  }

  function normalizeHeading(value) {
    const number = Number(value);
    if (!Number.isFinite(number)) return 0;
    return ((number % 360) + 360) % 360;
  }

  /** Diferenca angular pelo arco menor, em (-180, 180]. */
  function shortestAngle(from, to) {
    return ((normalizeHeading(to) - normalizeHeading(from) + 540) % 360) - 180;
  }

  function lerp(from, to, progress) {
    return from + (to - from) * clamp01(progress);
  }

  function text(value, maximum) {
    return String(value ?? "")
      .replace(/[\u0000-\u001F\u007F]/g, "")
      .slice(0, maximum || 80);
  }

  function normalizeUnit(raw) {
    if (!raw || typeof raw !== "object") return null;
    const id = typeof raw.id === "string" ? raw.id : "";
    if (!/^unit:[A-Za-z0-9_.-]{1,48}:[A-Za-z0-9_.-]{1,96}$/.test(id)) return null;
    const x = Number(raw.x);
    const y = Number(raw.y);
    if (!finite(x) || !finite(y)) return null;
    if (Math.abs(x) > 20000 || Math.abs(y) > 20000) return null;
    const z = Number(raw.z);
    const sampleTs = Number(raw.sampleTs);
    const category = CATEGORIES.has(String(raw.category)) ? String(raw.category) : "generic";
    const status = STATUSES.has(String(raw.status)) ? String(raw.status) : "active";
    return {
      id,
      unitId: text(raw.unitId ?? raw.plate, 48),
      plate: text(raw.plate, 16),
      orgCode: text(raw.orgCode, 48),
      x,
      y,
      z: finite(z) ? z : null,
      heading: normalizeHeading(raw.heading),
      sampleTs: Number.isFinite(sampleTs) ? sampleTs : 0,
      status,
      category,
      label: text(raw.label, 80),
    };
  }

  /**
   * Cria/atualiza o estado de interpolacao de uma unidade.
   * `existing` e o estado anterior (com from/to). `now` e performance.now().
   */
  function makeState(existing, unit, now, options) {
    const opts = options || {};
    if (!unit) return null;
    const current = existing ? sample(existing, now, opts.staleAfterMs || 5000) : null;
    const fromX = current ? current.x : unit.x;
    const fromY = current ? current.y : unit.y;
    const fromZ = current && current.z !== null ? current.z : (unit.z ?? 0);
    const fromHeading = current ? current.heading : unit.heading;
    const dx = unit.x - fromX;
    const dy = unit.y - fromY;
    const distance = Math.sqrt(dx * dx + dy * dy);
    const threshold = Number(opts.teleportThreshold) || 250;
    const snap = distance > threshold;
    const duration = clamp(Number(opts.tickMs) || 1000, 100, 2000);

    return {
      ...unit,
      // `unit` fields acima; campos de render abaixo.
      fromX: snap ? unit.x : fromX,
      fromY: snap ? unit.y : fromY,
      fromZ: snap ? (unit.z ?? 0) : fromZ,
      toX: unit.x,
      toY: unit.y,
      toZ: unit.z ?? 0,
      fromHeading: snap ? unit.heading : fromHeading,
      toHeading: unit.heading,
      startedAt: now,
      duration,
      lastSeenAt: now,
      teleport: snap,
      rendered: {
        x: snap ? unit.x : fromX,
        y: snap ? unit.y : fromY,
        z: snap ? (unit.z ?? 0) : fromZ,
        heading: snap ? unit.heading : fromHeading,
        status: unit.status,
        stale: false,
      },
    };
  }

  /** Amostra o estado no instante `now`; congela no destino quando stale. */
  function sample(state, now, staleAfterMs) {
    if (!state) return null;
    const lastSeenAt = finite(state.lastSeenAt) ? state.lastSeenAt : now;
    const startedAt = finite(state.startedAt) ? state.startedAt : now;
    const age = Math.max(0, now - lastSeenAt);
    const stale = age > (Number(staleAfterMs) || 5000);
    const progress = stale ? 1 : clamp01((now - startedAt) / Math.max(1, state.duration || 1));
    const x = lerp(state.fromX, state.toX, progress);
    const y = lerp(state.fromY, state.toY, progress);
    const z = lerp(state.fromZ ?? 0, state.toZ ?? 0, progress);
    const heading = normalizeHeading(state.fromHeading + shortestAngle(state.fromHeading, state.toHeading) * progress);
    const status = stale ? "stale" : (state.status === "offduty" ? "offduty" : "active");
    const rendered = { x, y, z, heading, status, stale, progress };
    state.rendered = rendered;
    return rendered;
  }

  function markSeen(state, now) {
    if (state) state.lastSeenAt = now;
    return state;
  }

  /** Assinatura barata para decidir se a lista lateral precisa de rebuild. */
  function listSignature(units) {
    return (units || [])
      .map((unit) => `${unit.id}:${unit.plate}:${unit.status}`)
      .sort()
      .join("|");
  }

  return {
    CATEGORIES,
    STATUSES,
    clamp01,
    normalizeHeading,
    shortestAngle,
    lerp,
    normalizeUnit,
    makeState,
    sample,
    markSeen,
    listSignature,
  };
});
