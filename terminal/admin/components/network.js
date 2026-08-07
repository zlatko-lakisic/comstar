/** Host network panel — Wi‑Fi + IPv4 (ADR 0012). */

export function createNetwork(root, { api }) {
  root.innerHTML = `
    <div class="net">
      <p class="net__err mono" id="netErr" hidden></p>
      <div class="net__toolbar">
        <button type="button" class="btn" id="netRefresh">Refresh</button>
        <label class="net__check">
          <input type="checkbox" id="netWifiRadio" />
          Wi‑Fi radio
        </label>
      </div>

      <section class="net__step">
        <h3 class="net__step-title">Interfaces</h3>
        <div id="netDevices" class="net__devices"></div>
      </section>

      <section class="net__step">
        <h3 class="net__step-title">Wi‑Fi networks</h3>
        <div class="net__wifi-join">
          <div class="net__ssid-row">
            <select id="netSsid" class="mono" aria-label="SSID">
              <option value="">Scanning…</option>
            </select>
            <button type="button" class="btn" id="netSsidRefresh" title="Rescan Wi‑Fi">Refresh</button>
          </div>
          <input id="netWifiPass" type="password" placeholder="Password" autocomplete="new-password" />
          <button type="button" class="btn btn--primary" id="netWifiConnect">Connect</button>
          <button type="button" class="btn" id="netWifiDisconnect">Disconnect</button>
        </div>
        <div id="netWifiList" class="net__wifi-list mono"></div>
        <div id="netSavedWifi" class="net__saved mono"></div>
      </section>
    </div>
  `;

  const els = {
    err: root.querySelector('#netErr'),
    devices: root.querySelector('#netDevices'),
    wifiList: root.querySelector('#netWifiList'),
    saved: root.querySelector('#netSavedWifi'),
    wifiRadio: root.querySelector('#netWifiRadio'),
    ssid: root.querySelector('#netSsid'),
    wifiPass: root.querySelector('#netWifiPass'),
    ssidRefresh: root.querySelector('#netSsidRefresh'),
  };

  let busy = false;
  let lastSsid = '';
  let networksCache = [];

  function showErr(msg) {
    if (!msg) {
      els.err.hidden = true;
      els.err.textContent = '';
      return;
    }
    els.err.hidden = false;
    els.err.textContent = msg;
  }

  function methodLabel(m) {
    if (m === 'auto') return 'DHCP';
    if (m === 'manual') return 'Static';
    return m || '—';
  }

  function populateSsidSelect(networks, saved) {
    const prev = lastSsid || els.ssid.value;
    const bySsid = new Map();
    for (const n of networks || []) {
      const ssid = (n.ssid || '').trim();
      if (!ssid) continue;
      bySsid.set(ssid, n);
    }
    for (const s of saved || []) {
      const ssid = String(s || '').trim();
      if (!ssid || bySsid.has(ssid)) continue;
      bySsid.set(ssid, {
        ssid,
        signal: null,
        security: 'saved',
        in_use: false,
        saved: true,
      });
    }
    networksCache = [...bySsid.values()].sort((a, b) => {
      if (a.in_use && !b.in_use) return -1;
      if (!a.in_use && b.in_use) return 1;
      return (b.signal || 0) - (a.signal || 0) || a.ssid.localeCompare(b.ssid);
    });

    const opts = ['<option value="">Select a network…</option>'];
    for (const n of networksCache) {
      const bits = [];
      if (n.in_use) bits.push('connected');
      if (n.signal != null) bits.push(`${n.signal}%`);
      if (n.security) bits.push(n.security);
      if (n.saved && n.signal == null) bits.push('saved');
      const label = bits.length ? `${n.ssid}  (${bits.join(' · ')})` : n.ssid;
      const sel = n.ssid === prev ? ' selected' : '';
      opts.push(
        `<option value="${escapeHtml(n.ssid)}"${sel}>${escapeHtml(label)}</option>`,
      );
    }
    if (!networksCache.length) {
      opts.push(
        '<option value="" disabled>No networks found — turn radio on and Refresh</option>',
      );
    }
    els.ssid.innerHTML = opts.join('');
    if (prev && [...els.ssid.options].some((o) => o.value === prev)) {
      els.ssid.value = prev;
      lastSsid = prev;
    }
  }

  function renderDevices(devices) {
    if (!Array.isArray(devices) || !devices.length) {
      els.devices.innerHTML = '<p class="net__hint">No ethernet/Wi‑Fi devices.</p>';
      return;
    }
    els.devices.innerHTML = devices
      .map((d) => {
        const ipv4 = d.ipv4 || {};
        const addrs = (ipv4.addresses || []).join(', ') || '—';
        const dns = (ipv4.dns || []).join(', ');
        const wifiBit =
          d.type === 'wifi' && d.wifi && d.wifi.ssid
            ? `<div class="net__meta">SSID <span class="mono">${escapeHtml(d.wifi.ssid)}</span>${
                d.wifi.signal != null ? ` · ${d.wifi.signal}%` : ''
              }</div>`
            : '';
        const addr0 = (ipv4.addresses && ipv4.addresses[0]) || '';
        const [ipPart, prefPart] = addr0.includes('/')
          ? addr0.split('/')
          : [addr0, '24'];
        return `
        <article class="net__card" data-device="${escapeHtml(d.device)}">
          <header class="net__card-head">
            <strong class="mono">${escapeHtml(d.device)}</strong>
            <span class="net__badge">${escapeHtml(d.type)}</span>
            <span class="net__badge">${escapeHtml(d.state || '')}</span>
            <span class="net__badge">${methodLabel(ipv4.method)}</span>
          </header>
          <div class="net__meta">
            ${escapeHtml(addrs)}
            ${ipv4.gateway ? ` · gw ${escapeHtml(ipv4.gateway)}` : ''}
            ${dns ? ` · dns ${escapeHtml(dns)}` : ''}
          </div>
          ${wifiBit}
          <div class="net__meta mono">${escapeHtml(d.connection || 'no connection')} ${
            d.mac ? `· ${escapeHtml(d.mac)}` : ''
          }</div>
          <form class="net__ip-form" data-device="${escapeHtml(d.device)}">
            <label class="net__field">
              <span>IPv4</span>
              <select name="method">
                <option value="auto"${ipv4.method === 'auto' ? ' selected' : ''}>DHCP</option>
                <option value="manual"${ipv4.method === 'manual' ? ' selected' : ''}>Static</option>
              </select>
            </label>
            <label class="net__field net__static">
              <span>Address</span>
              <input name="address" class="mono" value="${escapeHtml(ipPart)}" placeholder="192.168.89.34" />
            </label>
            <label class="net__field net__static">
              <span>Prefix</span>
              <input name="prefix" class="mono" value="${escapeHtml(prefPart || '24')}" placeholder="24" />
            </label>
            <label class="net__field net__static">
              <span>Gateway</span>
              <input name="gateway" class="mono" value="${escapeHtml(ipv4.gateway || '')}" placeholder="192.168.89.1" />
            </label>
            <label class="net__field net__static">
              <span>DNS</span>
              <input name="dns" class="mono" value="${escapeHtml((ipv4.dns || []).join(', '))}" placeholder="192.168.89.1" />
            </label>
            <button type="submit" class="btn">Apply IP</button>
          </form>
        </article>`;
      })
      .join('');

    els.devices.querySelectorAll('.net__ip-form').forEach((form) => {
      const syncStatic = () => {
        const manual = form.method.value === 'manual';
        form.querySelectorAll('.net__static').forEach((el) => {
          el.hidden = !manual;
        });
      };
      form.method.addEventListener('change', syncStatic);
      syncStatic();
      form.addEventListener('submit', async (e) => {
        e.preventDefault();
        const device = form.getAttribute('data-device');
        const method = form.method.value;
        const body = { action: 'ipv4_set', device, method };
        if (method === 'manual') {
          body.address = form.address.value.trim();
          body.prefix = Number(form.prefix.value.trim());
          body.gateway = form.gateway.value.trim();
          body.dns = form.dns.value.trim();
        }
        if (
          !confirm(
            method === 'manual'
              ? `Set static ${body.address}/${body.prefix} on ${device}? Wrong values can lock you out.`
              : `Set DHCP on ${device}?`,
          )
        ) {
          return;
        }
        await post(body);
      });
    });
  }

  function renderWifi(networks, saved) {
    populateSsidSelect(networks, saved);
    const rows = networksCache;
    els.wifiList.innerHTML = rows.length
      ? `<table class="net__table"><thead><tr><th></th><th>SSID</th><th>Signal</th><th>Security</th></tr></thead><tbody>${rows
          .map((n) => {
            const ssid = n.ssid || '';
            return `<tr data-row-ssid="${escapeHtml(ssid)}" class="${ssid === els.ssid.value ? 'is-selected' : ''}">
              <td>${n.in_use ? '●' : ''}</td>
              <td>${escapeHtml(ssid)}</td>
              <td>${n.signal != null ? escapeHtml(String(n.signal)) : '—'}</td>
              <td>${escapeHtml(n.security || '')}</td>
            </tr>`;
          })
          .join('')}</tbody></table>`
      : '<p class="net__hint">No networks yet — turn Wi‑Fi on and hit Refresh.</p>';

    els.wifiList.querySelectorAll('[data-row-ssid]').forEach((row) => {
      row.addEventListener('click', () => {
        const ssid = row.getAttribute('data-row-ssid') || '';
        els.ssid.value = ssid;
        lastSsid = ssid;
        els.wifiList
          .querySelectorAll('tr.is-selected')
          .forEach((r) => r.classList.remove('is-selected'));
        row.classList.add('is-selected');
        els.wifiPass.focus();
      });
    });

    const savedList = Array.isArray(saved) ? saved : [];
    els.saved.innerHTML = savedList.length
      ? `Saved: ${savedList
          .map(
            (s) =>
              `<button type="button" class="btn btn--small" data-saved="${escapeHtml(s)}">${escapeHtml(s)}</button>
               <button type="button" class="btn btn--small btn--danger" data-forget="${escapeHtml(s)}" title="Forget">×</button>`,
          )
          .join(' ')}`
      : '';

    els.saved.querySelectorAll('[data-saved]').forEach((btn) => {
      btn.addEventListener('click', () => {
        const ssid = btn.getAttribute('data-saved') || '';
        els.ssid.value = ssid;
        lastSsid = ssid;
      });
    });
    els.saved.querySelectorAll('[data-forget]').forEach((btn) => {
      btn.addEventListener('click', async () => {
        const ssid = btn.getAttribute('data-forget');
        if (!confirm(`Forget saved network “${ssid}”?`)) return;
        await post({ action: 'wifi_forget', ssid });
      });
    });
  }

  function paint(data) {
    if (typeof data.wifi_radio === 'boolean') {
      els.wifiRadio.checked = data.wifi_radio;
    }
    renderDevices(data.devices);
    renderWifi(data.wifi_networks, data.saved_wifi);
    if (data.last_error) showErr(data.last_error);
    else if (data.ok === false) showErr(data.error || 'network_error');
    else showErr(null);
  }

  async function refresh({ scan = false } = {}) {
    if (busy) return;
    busy = true;
    if (scan) {
      els.ssidRefresh.disabled = true;
      els.ssidRefresh.textContent = 'Scanning…';
    }
    try {
      const q = scan ? '?scan=1' : '';
      const data = await api.get(`/api/network${q}`);
      paint(data);
    } catch (e) {
      showErr(e.message || String(e));
    } finally {
      busy = false;
      els.ssidRefresh.disabled = false;
      els.ssidRefresh.textContent = 'Refresh';
    }
  }

  async function post(body) {
    if (busy) return;
    busy = true;
    showErr(null);
    try {
      const data = await api.post('/api/network', body);
      paint(data);
    } catch (e) {
      showErr(e.message || String(e));
      try {
        await refresh();
      } catch {
        /* ignore */
      }
    } finally {
      busy = false;
    }
  }

  els.ssid.addEventListener('change', () => {
    lastSsid = els.ssid.value;
  });

  root.querySelector('#netRefresh').addEventListener('click', () => refresh());
  els.ssidRefresh.addEventListener('click', () => refresh({ scan: true }));
  els.wifiRadio.addEventListener('change', async () => {
    await post({ action: 'wifi_radio', enabled: els.wifiRadio.checked });
    if (els.wifiRadio.checked) await refresh({ scan: true });
  });
  root.querySelector('#netWifiConnect').addEventListener('click', () => {
    const ssid = els.ssid.value.trim();
    if (!ssid) {
      showErr('Select an SSID');
      return;
    }
    post({
      action: 'wifi_connect',
      ssid,
      password: els.wifiPass.value,
    });
  });
  root.querySelector('#netWifiDisconnect').addEventListener('click', () => {
    post({ action: 'wifi_disconnect' });
  });

  // Initial load: status + Wi‑Fi scan so the SSID list is filled.
  refresh({ scan: true });

  return {
    refresh,
    onShow() {
      refresh({ scan: true });
    },
    applyStatusSnippet() {
      /* status poll does not carry full network — no-op */
    },
  };
}

function escapeHtml(s) {
  return String(s ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}
