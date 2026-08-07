/** Host network panel — Wi‑Fi + IPv4 (ADR 0012). */

export function createNetwork(root, { api }) {
  root.innerHTML = `
    <div class="net">
      <p class="net__err mono" id="netErr" hidden></p>
      <div class="net__toolbar">
        <button type="button" class="btn" id="netRefresh">Refresh</button>
        <button type="button" class="btn" id="netScan">Scan Wi‑Fi</button>
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
          <input id="netSsid" class="mono" type="text" placeholder="SSID" autocomplete="off" />
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
  };

  let busy = false;

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
    const rows = Array.isArray(networks) ? networks : [];
    els.wifiList.innerHTML = rows.length
      ? `<table class="net__table"><thead><tr><th></th><th>SSID</th><th>Signal</th><th>Security</th><th></th></tr></thead><tbody>${rows
          .map((n) => {
            const ssid = n.ssid || '';
            return `<tr>
              <td>${n.in_use ? '●' : ''}</td>
              <td>${escapeHtml(ssid)}</td>
              <td>${n.signal != null ? escapeHtml(String(n.signal)) : '—'}</td>
              <td>${escapeHtml(n.security || '')}</td>
              <td><button type="button" class="btn btn--small" data-pick-ssid="${escapeHtml(ssid)}">Use</button></td>
            </tr>`;
          })
          .join('')}</tbody></table>`
      : '<p class="net__hint">No networks (turn radio on and scan).</p>';

    els.wifiList.querySelectorAll('[data-pick-ssid]').forEach((btn) => {
      btn.addEventListener('click', () => {
        els.ssid.value = btn.getAttribute('data-pick-ssid') || '';
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
        els.ssid.value = btn.getAttribute('data-saved') || '';
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
    try {
      const q = scan ? '?scan=1' : '';
      const data = await api.get(`/api/network${q}`);
      paint(data);
    } catch (e) {
      showErr(e.message || String(e));
    } finally {
      busy = false;
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

  root.querySelector('#netRefresh').addEventListener('click', () => refresh());
  root.querySelector('#netScan').addEventListener('click', () => refresh({ scan: true }));
  els.wifiRadio.addEventListener('change', () => {
    post({ action: 'wifi_radio', enabled: els.wifiRadio.checked });
  });
  root.querySelector('#netWifiConnect').addEventListener('click', () => {
    const ssid = els.ssid.value.trim();
    if (!ssid) {
      showErr('SSID required');
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

  refresh();

  return {
    refresh,
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
