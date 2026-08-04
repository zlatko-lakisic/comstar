const PROC_CLASS = {
  bridge: '',
  audio: 'is-audio',
  kiosk: 'is-kiosk',
  stt: 'is-stt',
  health: 'is-health',
};

function unwrapSseData(raw) {
  if (raw == null) return '';
  if (typeof raw !== 'string') {
    try { return JSON.stringify(raw); } catch { return String(raw); }
  }
  let cur = raw;
  // Server sends jsonEncode(line); unwrap one JSON string layer when present.
  for (let i = 0; i < 2; i += 1) {
    try {
      const parsed = JSON.parse(cur);
      if (typeof parsed === 'string') {
        cur = parsed;
        continue;
      }
      return JSON.stringify(parsed);
    } catch {
      return cur;
    }
  }
  return cur;
}

function parseLine(raw) {
  const text = unwrapSseData(raw);
  try {
    const o = typeof text === 'string' ? JSON.parse(text) : text;
    if (!o || typeof o !== 'object') {
      return {
        raw: text,
        ts: Date.now(),
        level: 'info',
        proc: 'bridge',
        evt: '',
        msg: String(text),
        data: null,
        injected: false,
      };
    }
    return {
      raw: text,
      ts: o.ts,
      level: (o.level || 'info').toLowerCase(),
      proc: o.proc || 'bridge',
      evt: o.evt || '',
      msg: o.msg || '',
      data: o.data && typeof o.data === 'object' ? o.data : null,
      injected: o.data?.src === 'injected' || o.src === 'injected',
    };
  } catch {
    return {
      raw: text,
      ts: Date.now(),
      level: 'info',
      proc: 'bridge',
      evt: '',
      msg: text,
      data: null,
      injected: false,
    };
  }
}

function fmtTime(ts) {
  const d = new Date(typeof ts === 'number' && ts > 1e12 ? ts : Number(ts));
  if (Number.isNaN(d.getTime())) return '--';
  const pad = (n, w = 2) => String(n).padStart(w, '0');
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${pad(d.getMilliseconds(), 3)}`;
}

function fields(data) {
  if (!data) return '';
  return Object.entries(data)
    .filter(([k]) => k !== 'src')
    .slice(0, 8)
    .map(([k, v]) => `<span class="log-key">${escapeHtml(k)}=</span>${escapeHtml(v)}`)
    .join(' ');
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

export function createLogs(root, controlsRoot, { apiUrl, authHeaders, onUnauthorized }) {
  let abort = null;
  let reconnectTimer = null;
  let paused = false;
  let wrap = false;
  let filter = '';
  let unit = 'all';
  let buffer = [];
  let pending = [];
  let stickBottom = true;
  let newCount = 0;
  let raf = 0;
  let alive = true;
  const maxRows = 2000;

  controlsRoot.innerHTML = `
    <select id="logUnit">
      <option value="all">all</option>
      <option value="bridge">bridge</option>
      <option value="audio">audio</option>
      <option value="kiosk">kiosk</option>
      <option value="stt">stt</option>
      <option value="health">health</option>
    </select>
    <input id="logFilter" type="text" placeholder="filter…" />
    <button type="button" class="btn" id="logPause">Pause</button>
    <button type="button" class="btn" id="logClear">Clear</button>
    <button type="button" class="btn" id="logWrap">Wrap</button>
    <button type="button" class="btn" id="logDl">Download</button>
  `;

  root.innerHTML = `<div id="logView"></div><button type="button" class="btn logs-jump" id="logJump" hidden></button>`;
  const view = root.querySelector('#logView');
  const jump = root.querySelector('#logJump');

  function matches(row) {
    if (unit !== 'all' && row.proc !== unit) return false;
    if (!filter) return true;
    const f = filter.toLowerCase();
    return String(row.raw).toLowerCase().includes(f) || row.evt.toLowerCase().includes(f);
  }

  function rowHtml(row) {
    const levelClass = row.level === 'error' ? 'is-error'
      : row.level === 'warn' ? 'is-warn'
        : row.level === 'debug' ? 'is-debug' : '';
    const inj = row.injected ? 'is-inj' : '';
    const wrapClass = wrap ? 'is-wrap' : '';
    const procClass = PROC_CLASS[row.proc] || '';
    const chip = row.injected ? '<span class="inj-chip">INJ</span>' : '';
    const body = `${chip}<span class="log-evt">${escapeHtml(row.evt)}</span> ${escapeHtml(row.msg)} ${fields(row.data)}`;
    return `<div class="log-row ${levelClass} ${inj} ${wrapClass}">
      <span class="log-time">${fmtTime(row.ts)}</span>
      <span class="log-proc ${procClass}">${escapeHtml(row.proc)}</span>
      <span class="log-body">${body}</span>
    </div>`;
  }

  function render() {
    const shown = buffer.filter(matches);
    view.innerHTML = shown.map(rowHtml).join('');
    if (stickBottom) root.scrollTop = root.scrollHeight;
  }

  function scheduleRender() {
    if (raf) return;
    raf = requestAnimationFrame(() => {
      raf = 0;
      render();
    });
  }

  function noteDisconnect() {
    const div = document.createElement('div');
    div.className = 'log-divider';
    div.textContent = 'stream disconnected, reconnecting…';
    view.appendChild(div);
  }

  function push(raw) {
    const row = parseLine(raw);
    if (paused) {
      pending.push(row);
      controlsRoot.querySelector('#logPause').textContent = `Resume (${pending.length})`;
      return;
    }
    buffer.push(row);
    if (buffer.length > maxRows) buffer = buffer.slice(-maxRows);
    if (!stickBottom) {
      newCount += 1;
      jump.hidden = false;
      jump.textContent = `↓ ${newCount} new`;
      return;
    }
    scheduleRender();
  }

  function ingestSseBlock(block) {
    for (const line of block.split('\n')) {
      if (!line.startsWith('data:')) continue;
      push(line.slice(5).trimStart());
    }
  }

  function scheduleReconnect(ms = 1500) {
    if (!alive) return;
    clearTimeout(reconnectTimer);
    reconnectTimer = setTimeout(() => connect(), ms);
  }

  async function connect() {
    clearTimeout(reconnectTimer);
    if (abort) abort.abort();
    abort = new AbortController();

    try {
      const res = await fetch(apiUrl('/api/logs'), {
        headers: {
          Accept: 'text/event-stream',
          ...(authHeaders ? authHeaders() : {}),
        },
        signal: abort.signal,
        cache: 'no-store',
      });

      if (res.status === 401) {
        onUnauthorized?.();
        scheduleReconnect(3000);
        return;
      }
      if (!res.ok || !res.body) {
        noteDisconnect();
        scheduleReconnect();
        return;
      }

      const reader = res.body.getReader();
      const dec = new TextDecoder();
      let buf = '';
      while (alive) {
        const { done, value } = await reader.read();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        const parts = buf.split('\n\n');
        buf = parts.pop() || '';
        for (const block of parts) ingestSseBlock(block);
      }
    } catch (e) {
      if (e?.name === 'AbortError') return;
    }

    if (!alive) return;
    noteDisconnect();
    scheduleReconnect();
  }

  root.addEventListener('scroll', () => {
    const atBottom = root.scrollHeight - root.scrollTop - root.clientHeight < 40;
    stickBottom = atBottom;
    if (atBottom) {
      newCount = 0;
      jump.hidden = true;
      scheduleRender();
    }
  });

  jump.addEventListener('click', () => {
    stickBottom = true;
    newCount = 0;
    jump.hidden = true;
    render();
    root.scrollTop = root.scrollHeight;
  });

  controlsRoot.querySelector('#logUnit').addEventListener('change', (e) => {
    unit = e.target.value;
    render();
  });
  controlsRoot.querySelector('#logFilter').addEventListener('input', (e) => {
    filter = e.target.value.trim();
    render();
  });
  controlsRoot.querySelector('#logPause').addEventListener('click', () => {
    paused = !paused;
    if (!paused) {
      buffer.push(...pending);
      pending = [];
      if (buffer.length > maxRows) buffer = buffer.slice(-maxRows);
      controlsRoot.querySelector('#logPause').textContent = 'Pause';
      render();
    } else {
      controlsRoot.querySelector('#logPause').textContent = 'Resume (0)';
    }
  });
  controlsRoot.querySelector('#logClear').addEventListener('click', () => {
    buffer = [];
    pending = [];
    render();
  });
  controlsRoot.querySelector('#logWrap').addEventListener('click', () => {
    wrap = !wrap;
    render();
  });
  controlsRoot.querySelector('#logDl').addEventListener('click', () => {
    const blob = new Blob([buffer.map((r) => r.raw).join('\n')], { type: 'text/plain' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = `comstar-logs-${Date.now()}.jsonl`;
    a.click();
  });

  connect();
  return {
    reconnect: connect,
    destroy: () => {
      alive = false;
      clearTimeout(reconnectTimer);
      abort?.abort();
    },
  };
}
