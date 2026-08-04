import { createApi } from './lib/api.js';
import { fmtAge, fmtClock, fmtNoContact, fmtUptime } from './lib/fmt.js';
import { createRailEmblem, createGateEmblem } from './components/emblem.js';
import { createHealth } from './components/health.js';
import { createLogs } from './components/logs.js';
import { createActions } from './components/actions.js';
import { createInject } from './components/inject.js';

const params = new URLSearchParams(location.search);
let token = params.get('token') || sessionStorage.getItem('comstar_lan_token') || '';

const els = {
  app: document.getElementById('app'),
  gate: document.getElementById('tokenGate'),
  gateToken: document.getElementById('gateToken'),
  gateErr: document.getElementById('gateErr'),
  gateEmblem: document.getElementById('gateEmblem'),
  bindBadge: document.getElementById('bindBadge'),
  devBadge: document.getElementById('devBadge'),
  lanRule: document.getElementById('lanRule'),
  hostname: document.getElementById('hostname'),
  uptime: document.getElementById('uptime'),
  liveDot: document.getElementById('liveDot'),
  clock: document.getElementById('clock'),
  railEmblem: document.getElementById('railEmblem'),
  railState: document.getElementById('railState'),
  railUser: document.getElementById('railUser'),
  railKv: document.getElementById('railKv'),
  railFresh: document.getElementById('railFresh'),
  healthFresh: document.getElementById('healthFresh'),
  actionsFresh: document.getElementById('actionsFresh'),
  healthGrid: document.getElementById('healthGrid'),
  metricsRow: document.getElementById('metricsRow'),
  healthPanel: document.getElementById('healthPanel'),
  actionsPanel: document.getElementById('actionsPanel'),
  actionsRoot: document.getElementById('actionsRoot'),
  injectRoot: document.getElementById('injectRoot'),
  logsControls: document.getElementById('logsControls'),
  logsRoot: document.getElementById('logsRoot'),
  modalRoot: document.getElementById('modalRoot'),
};

function showGate(msg) {
  els.app.hidden = true;
  els.gate.hidden = false;
  if (msg) {
    els.gateErr.hidden = false;
    els.gateErr.textContent = msg;
  }
  if (!els.gate.dataset.ready) {
    const g = createGateEmblem(els.gateEmblem);
    g.setState('unreachable');
    els.gate.dataset.ready = '1';
  }
}

function showApp() {
  els.gate.hidden = true;
  els.app.hidden = false;
}

const api = createApi({
  getToken: () => token,
  setToken: (t) => {
    token = t;
    if (t) sessionStorage.setItem('comstar_lan_token', t);
    else sessionStorage.removeItem('comstar_lan_token');
  },
  onUnauthorized: () => showGate('unauthorized'),
});

const rail = createRailEmblem(els.railEmblem);
const health = createHealth(els.healthGrid, els.metricsRow);
createActions(els.actionsRoot, els.modalRoot, {
  api,
  onDanger: () => rail.setUnreachable(),
});
const logs = createLogs(els.logsRoot, els.logsControls, {
  apiUrl: api.url,
  authHeaders: api.authHeaders,
  onUnauthorized: () => showGate('unauthorized'),
});

els.gateToken.value = token;
els.gateToken.addEventListener('keydown', async (e) => {
  if (e.key !== 'Enter') return;
  token = els.gateToken.value.trim();
  if (token) sessionStorage.setItem('comstar_lan_token', token);
  els.gateErr.hidden = true;
  showApp();
  logs.reconnect();
  await tick(true);
});

let lastOkAt = 0;
let pollTimer = null;
let injectReady = false;

function setFreshness(el, ageSec, failing) {
  el.classList.toggle('is-amber', failing || ageSec >= 3);
  if (failing) {
    el.textContent = fmtNoContact(ageSec);
    return;
  }
  el.textContent = fmtAge(ageSec);
}

function renderRail(status, emblemName) {
  const labels = {
    ambient: 'AMBIENT',
    noticed: 'NOTICED',
    engaged: 'ENGAGED',
    listening: 'LISTENING',
    responding: 'RESPONDING',
    sleeping: 'SLEEPING',
    degraded: 'DEGRADED',
    unreachable: 'NO CONTACT',
  };
  els.railState.textContent = labels[emblemName] || String(emblemName).toUpperCase();
  els.railState.classList.toggle('is-amber', emblemName === 'degraded');
  els.railState.classList.toggle('is-dim', emblemName === 'unreachable');
  els.railUser.textContent = status?.userid || (status?.guest ? 'guest' : '');

  const rows = [
    ['session', status?.session_open ? 'open' : 'closed'],
    ['reach', status?.reach_active ? 'ok' : 'down'],
    ['sleeping', status?.sleeping ? 'yes' : 'no'],
    ['wake', status?.wake_enabled ? 'on' : 'off'],
    ['uptime', fmtUptime(status?.uptime_s)],
  ];
  els.railKv.innerHTML = rows.map(([k, v]) => `<dt>${k}</dt><dd class="mono">${v}</dd>`).join('');
}

function renderChrome(status) {
  els.hostname.textContent = status.hostname || 'comstar';
  els.uptime.textContent = `up ${fmtUptime(status.uptime_s)}`;
  els.clock.textContent = fmtClock();

  const lan = !!status.lan_bound;
  els.bindBadge.textContent = lan
    ? `LAN ${status.bind || '0.0.0.0'}:${status.port || 8781}`
    : 'LOOPBACK';
  els.bindBadge.classList.toggle('badge--amber', lan);
  els.lanRule.hidden = !lan;

  els.devBadge.hidden = !status.inject_enabled;
  if (status.inject_enabled && !injectReady) {
    createInject(els.injectRoot, { api, visible: true });
    injectReady = true;
  }
}

async function tick(force) {
  try {
    const status = await api.get('/api/status');
    api.resetBackoff();
    lastOkAt = performance.now();
    els.liveDot.classList.remove('is-miss', 'is-dead');
    els.liveDot.classList.remove('is-pulse');
    void els.liveDot.offsetWidth;
    els.liveDot.classList.add('is-pulse');

    const degraded = !status.ao_ok || !status.cpai_ok ||
      !status.kiosk_connected || !status.audio_connected;
    const emblemName = rail.apply(status, { contactOk: true, degraded });
    renderChrome(status);
    renderRail(status, emblemName);
    health.render(status);

    [els.healthPanel, els.actionsPanel].forEach((p) => {
      p.classList.remove('is-stale', 'is-nocontact');
    });
    setFreshness(els.railFresh, 0.4, false);
    setFreshness(els.healthFresh, 0.4, false);
    setFreshness(els.actionsFresh, 0.4, false);

    showApp();
    schedule(document.hidden ? 15000 : 2000);
  } catch (e) {
    const age = lastOkAt ? (performance.now() - lastOkAt) / 1000 : 30;
    if (e.code === 401) {
      showGate('Enter LAN token');
      schedule(api.nextBackoffMs());
      return;
    }
    rail.setUnreachable();
    els.railState.textContent = 'NO CONTACT';
    els.railState.classList.add('is-dim');
    els.liveDot.classList.add(api.misses >= 2 ? 'is-dead' : 'is-miss');
    [els.healthPanel, els.actionsPanel].forEach((p) => {
      p.classList.add(age > 10 ? 'is-nocontact' : 'is-stale');
    });
    setFreshness(els.railFresh, age, true);
    setFreshness(els.healthFresh, age, true);
    setFreshness(els.actionsFresh, age, true);
    schedule(api.nextBackoffMs());
  }
}

function schedule(ms) {
  clearTimeout(pollTimer);
  pollTimer = setTimeout(() => tick(false), ms);
}

document.addEventListener('visibilitychange', () => {
  if (!document.hidden) tick(true);
});

setInterval(() => { els.clock.textContent = fmtClock(); }, 1000);

if (!token && location.hostname !== '127.0.0.1' && location.hostname !== 'localhost') {
  showGate('');
} else {
  showApp();
}
tick(true);

window.addEventListener('beforeunload', () => logs.destroy());
