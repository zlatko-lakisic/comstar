/** Road VPN setup, initialize, and health monitor (ADR 0011). */

const ICON_POWER = `
<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
  <path fill="currentColor" d="M12 3a1 1 0 0 1 1 1v8a1 1 0 1 1-2 0V4a1 1 0 0 1 1-1Zm5.66 2.34a1 1 0 0 1 0 1.41A7 7 0 1 1 6.34 6.75a1 1 0 1 1 1.41-1.41 5 5 0 1 0 7.07 0 1 1 0 0 1 1.41-1.41Z"/>
</svg>`;

const ICON_DISC = `
<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
  <path fill="currentColor" d="M4.22 4.22a1 1 0 0 1 1.42 0l14.14 14.14a1 1 0 1 1-1.42 1.42L15.4 17.82A7.5 7.5 0 0 1 6.18 8.6L4.22 6.64a1 1 0 0 1 0-1.42ZM8.6 11.02a4.5 4.5 0 0 0 4.38 4.38l-4.38-4.38Zm6.78 1.96a4.5 4.5 0 0 0-4.36-4.36l4.36 4.36Z"/>
  <path fill="currentColor" d="M12 5.5a6.5 6.5 0 0 1 6.5 6.5 1 1 0 1 1-2 0A4.5 4.5 0 0 0 12 7.5a1 1 0 1 1 0-2Z" opacity=".55"/>
</svg>`;

const ICON_SPIN = `
<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
  <path fill="currentColor" d="M12 4a8 8 0 0 1 8 8 1 1 0 1 1-2 0 6 6 0 1 0-6 6 1 1 0 1 1 0 2 8 8 0 0 1 0-16Z"/>
</svg>`;

const ICON_LINK = `
<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
  <path fill="currentColor" d="M10.59 13.41a1 1 0 0 1 0-1.41l2.83-2.83a3 3 0 1 1 4.24 4.24l-1.41 1.42a1 1 0 1 1-1.42-1.42l1.42-1.41a1 1 0 1 0-1.42-1.42l-2.83 2.83a1 1 0 0 1-1.41 0Zm2.82-2.82a1 1 0 0 1 0 1.41l-2.83 2.83a3 3 0 1 1-4.24-4.24l1.41-1.42a1 1 0 0 1 1.42 1.42L6.76 12.6a1 1 0 1 0 1.41 1.41l2.83-2.83a1 1 0 0 1 1.41 0Z"/>
</svg>`;

function linkStateFromData(data) {
  const mon = data.monitor_state || 'idle';
  if (mon === 'healing' || (data.enabled && !data.at_home && !data.vpn_active && mon === 'watching')) {
    return 'connecting';
  }
  if (data.vpn_active) return 'connected';
  return 'disconnected';
}

export function createRoad(root, { api, onStatus } = {}) {
  root.innerHTML = `
    <div class="road">
      <div class="road__icons" id="roadIcons" aria-live="polite">
        <div class="vpn-chip vpn-chip--enabled is-off" id="vpnEnabledChip" title="Monitor off">
          <span class="vpn-chip__glyph">${ICON_POWER}</span>
          <span class="vpn-chip__label">Disabled</span>
        </div>
        <div class="vpn-chip vpn-chip--link is-down" id="vpnLinkChip" title="Not connected">
          <span class="vpn-chip__glyph" id="vpnLinkGlyph">${ICON_DISC}</span>
          <span class="vpn-chip__label" id="vpnLinkLabel">Not connected</span>
        </div>
      </div>

      <div class="road__banner" id="roadBanner"></div>
      <div class="road__kv" id="roadKv"></div>
      <p class="road__err mono" id="roadErr" hidden></p>

      <section class="road__step">
        <h3 class="road__step-title">1 · Prerequisites</h3>
        <p class="road__hint">Install once on the Pi: <span class="mono">make road-vpn</span></p>
        <div class="road__prereq mono" id="roadPrereq"></div>
        <button type="button" class="btn" id="roadCheckPrereq">Recheck</button>
      </section>

      <section class="road__step">
        <h3 class="road__step-title">2 · Configure &amp; initialize</h3>
        <form class="road__form" id="roadForm">
          <label class="road__field">
            <span>Protocol</span>
            <select id="roadProtocol">
              <option value="openvpn">OpenVPN</option>
              <option value="l2tp">L2TP/IPsec</option>
              <option value="auto">Auto (OVPN then L2TP)</option>
            </select>
          </label>
          <label class="road__field">
            <span>Home CIDRs (comma-separated)</span>
            <input id="roadCidrs" class="mono" type="text" autocomplete="off" />
          </label>
          <label class="road__field">
            <span>Health URL (empty = Ada AO /health)</span>
            <input id="roadHealthUrl" class="mono" type="text" placeholder="http://10.0.10.16:8765/health" />
          </label>
          <div class="road__row">
            <label class="road__field" data-proto="openvpn" id="roadOvpnNameField">
              <span>OpenVPN NM name</span>
              <input id="roadOvpnName" class="mono" type="text" />
            </label>
            <label class="road__field" data-proto="l2tp" id="roadL2tpNameField">
              <span>L2TP NM name</span>
              <input id="roadL2tpName" class="mono" type="text" />
            </label>
          </div>

          <details class="road__secrets" open>
            <summary>Credentials (saved values are reloaded into these fields)</summary>
            <div class="road__secrets-body">
              <div class="road__proto-fields" data-proto="openvpn" id="roadOvpnCreds">
                <label class="road__field">
                  <span>OpenVPN (.ovpn paste) — match router cipher/auth/proto</span>
                  <textarea id="roadOvpnText" class="mono" rows="5" placeholder="client&#10;dev tun&#10;proto tcp-client&#10;cipher AES-128-CBC&#10;auth SHA1&#10;…"></textarea>
                </label>
                <div class="road__row">
                  <label class="road__field">
                    <span>PPP username (MikroTik secret)</span>
                    <input id="roadOvpnUser" class="mono" type="text" autocomplete="username" />
                  </label>
                  <label class="road__field">
                    <span>PPP password</span>
                    <input id="roadOvpnUserPass" type="password" autocomplete="new-password" />
                  </label>
                </div>
                <label class="road__field">
                  <span>Private-key passphrase (export only; not PPP)</span>
                  <input id="roadOvpnPass" type="password" autocomplete="new-password" />
                </label>
              </div>
              <div class="road__proto-fields" data-proto="l2tp" id="roadL2tpCreds">
                <div class="road__row">
                  <label class="road__field">
                    <span>L2TP gateway</span>
                    <input id="roadL2tpGw" class="mono" type="text" />
                  </label>
                  <label class="road__field">
                    <span>L2TP user</span>
                    <input id="roadL2tpUser" class="mono" type="text" />
                  </label>
                </div>
                <div class="road__row">
                  <label class="road__field">
                    <span>L2TP password</span>
                    <input id="roadL2tpPass" type="password" autocomplete="new-password" />
                  </label>
                  <label class="road__field">
                    <span>IPsec PSK</span>
                    <input id="roadL2tpPsk" type="password" autocomplete="new-password" />
                  </label>
                </div>
              </div>
            </div>
          </details>

          <div class="road__actions">
            <button type="button" class="btn btn--primary" id="roadInit">Initialize VPN</button>
            <button type="submit" class="btn" id="roadSave">Save settings</button>
          </div>
        </form>
      </section>

      <section class="road__step">
        <h3 class="road__step-title">3 · Monitor &amp; heal</h3>
        <label class="road__check">
          <input type="checkbox" id="roadEnabled" />
          Enable health monitor (auto phone-home + heal when off-home)
        </label>
        <p class="road__hint">
          When enabled off-home: keep the tunnel up, probe the health URL, and bounce/reconnect on failure with backoff.
          At home: VPN is torn down so LAN wins.
        </p>
        <div class="road__actions">
          <button type="button" class="btn" id="roadReconcile">Heal now</button>
          <button type="button" class="btn" id="roadConnect">Connect</button>
          <button type="button" class="btn btn--danger" id="roadDisconnect">Disconnect</button>
        </div>
      </section>
    </div>
  `;

  const els = {
    enabledChip: root.querySelector('#vpnEnabledChip'),
    linkChip: root.querySelector('#vpnLinkChip'),
    linkGlyph: root.querySelector('#vpnLinkGlyph'),
    linkLabel: root.querySelector('#vpnLinkLabel'),
    banner: root.querySelector('#roadBanner'),
    kv: root.querySelector('#roadKv'),
    err: root.querySelector('#roadErr'),
    prereq: root.querySelector('#roadPrereq'),
    enabled: root.querySelector('#roadEnabled'),
    protocol: root.querySelector('#roadProtocol'),
    cidrs: root.querySelector('#roadCidrs'),
    healthUrl: root.querySelector('#roadHealthUrl'),
    ovpnName: root.querySelector('#roadOvpnName'),
    l2tpName: root.querySelector('#roadL2tpName'),
    form: root.querySelector('#roadForm'),
    ovpnText: root.querySelector('#roadOvpnText'),
    ovpnUser: root.querySelector('#roadOvpnUser'),
    ovpnUserPass: root.querySelector('#roadOvpnUserPass'),
    ovpnPass: root.querySelector('#roadOvpnPass'),
    l2tpGw: root.querySelector('#roadL2tpGw'),
    l2tpUser: root.querySelector('#roadL2tpUser'),
    l2tpPass: root.querySelector('#roadL2tpPass'),
    l2tpPsk: root.querySelector('#roadL2tpPsk'),
  };

  function showErr(msg) {
    if (!msg) {
      els.err.hidden = true;
      els.err.textContent = '';
      return;
    }
    els.err.hidden = false;
    els.err.textContent = msg;
  }

  function syncProtocolFields() {
    const proto = els.protocol.value || 'openvpn';
    const showOvpn = proto === 'openvpn' || proto === 'auto';
    const showL2tp = proto === 'l2tp' || proto === 'auto';
    root.querySelectorAll('[data-proto="openvpn"]').forEach((el) => {
      el.hidden = !showOvpn;
    });
    root.querySelectorAll('[data-proto="l2tp"]').forEach((el) => {
      el.hidden = !showL2tp;
    });
  }

  els.protocol.addEventListener('change', syncProtocolFields);

  function bannerClass(data) {
    if (!data.prereqs_ok) return 'is-red';
    if (data.monitor_state === 'healthy') return 'is-ok';
    if (data.monitor_state === 'healing' || data.monitor_state === 'watching') return 'is-amber';
    if (data.monitor_state === 'degraded' || data.last_error) return 'is-red';
    return '';
  }

  function bannerText(data) {
    if (!data.prereqs_ok) return 'Prerequisites missing — run make road-vpn on the Pi';
    if (data.at_home) return data.enabled
      ? 'At home · monitor idle (VPN down on purpose)'
      : 'At home · monitor off';
    if (!data.enabled) return 'Off-home · monitor disabled';
    const mon = data.monitor_state || '—';
    const health = data.health_ok == null ? '—' : (data.health_ok ? 'ok' : 'fail');
    const vpn = data.vpn_active ? (data.active_protocol || 'up') : 'down';
    return `Off-home · monitor ${mon} · vpn ${vpn} · health ${health}`;
  }

  function setIcons(data) {
    const on = !!data.enabled;
    els.enabledChip.classList.toggle('is-on', on);
    els.enabledChip.classList.toggle('is-off', !on);
    els.enabledChip.title = on ? 'Monitor enabled' : 'Monitor disabled';
    els.enabledChip.querySelector('.vpn-chip__label').textContent = on ? 'Enabled' : 'Disabled';

    const link = linkStateFromData(data);
    els.linkChip.classList.remove('is-down', 'is-connecting', 'is-up');
    if (link === 'connected') {
      els.linkChip.classList.add('is-up');
      els.linkGlyph.innerHTML = ICON_LINK;
      els.linkLabel.textContent = 'Connected';
      els.linkChip.title = data.active_connection
        ? `Connected (${data.active_protocol || 'vpn'}: ${data.active_connection})`
        : 'Connected';
    } else if (link === 'connecting') {
      els.linkChip.classList.add('is-connecting');
      els.linkGlyph.innerHTML = ICON_SPIN;
      els.linkLabel.textContent = 'Connecting';
      els.linkChip.title = 'Connecting / healing';
    } else {
      els.linkChip.classList.add('is-down');
      els.linkGlyph.innerHTML = ICON_DISC;
      els.linkLabel.textContent = 'Not connected';
      els.linkChip.title = 'Not connected';
    }

    onStatus?.({
      enabled: on,
      link,
      monitor_state: data.monitor_state,
      vpn_active: !!data.vpn_active,
    });
  }

  function fillPrereq(prereqs) {
    const checks = (prereqs && prereqs.checks) || {};
    const lines = Object.keys(checks).map((k) => {
      const v = checks[k];
      const mark = v === true ? 'ok' : (v === false ? 'MISSING' : String(v));
      return `${k}: ${mark}`;
    });
    if (prereqs && prereqs.hint) lines.push(prereqs.hint);
    els.prereq.textContent = lines.join('\n') || '—';
  }

  function escapeHtml(s) {
    return s
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function fillStatus(data) {
    setIcons(data);
    els.banner.textContent = bannerText(data);
    els.banner.className = `road__banner ${bannerClass(data)}`;
    if (data.prereqs) fillPrereq(data.prereqs);

    const rows = [
      ['monitor', data.monitor_state || '—'],
      ['enabled', data.enabled ? 'yes' : 'no'],
      ['at home', data.at_home ? 'yes' : 'no'],
      ['vpn', data.vpn_active ? `${data.active_protocol} (${data.active_connection})` : 'down'],
      ['health', data.health_ok == null ? '—' : (data.health_ok ? 'ok' : 'fail')],
      ['health url', data.health_url_resolved || '—'],
      ['heals', String(data.heal_count ?? 0)],
      ['failures', String(data.consecutive_failures ?? 0)],
      ['ovpn profile', data.openvpn_profile_present ? 'yes' : 'no'],
      ['l2tp profile', data.l2tp_profile_present ? 'yes' : 'no'],
      ['last error', data.last_error || '—'],
    ];
    els.kv.innerHTML = rows
      .map(([k, v]) => `<dt>${k}</dt><dd class="mono">${escapeHtml(String(v))}</dd>`)
      .join('');
  }

  function fillConfig(data) {
    els.enabled.checked = !!data.enabled;
    els.protocol.value = data.protocol || 'openvpn';
    els.cidrs.value = (data.home_cidrs || []).join(', ');
    els.healthUrl.value = data.health_url || '';
    els.ovpnName.value = data.openvpn_connection || '';
    els.l2tpName.value = data.l2tp_connection || '';

    const secrets = data.secrets || {};
    if (secrets.openvpn && typeof secrets.openvpn === 'object') {
      const ovpn = secrets.openvpn;
      if (typeof ovpn.ovpn === 'string') els.ovpnText.value = ovpn.ovpn;
      if (typeof ovpn.username === 'string') els.ovpnUser.value = ovpn.username;
      if (typeof ovpn.password === 'string') els.ovpnUserPass.value = ovpn.password;
      if (typeof ovpn.passphrase === 'string') els.ovpnPass.value = ovpn.passphrase;
    }
    if (secrets.l2tp && typeof secrets.l2tp === 'object') {
      const l2tp = secrets.l2tp;
      if (typeof l2tp.gateway === 'string') els.l2tpGw.value = l2tp.gateway;
      if (typeof l2tp.user === 'string') els.l2tpUser.value = l2tp.user;
      if (typeof l2tp.password === 'string') els.l2tpPass.value = l2tp.password;
      if (typeof l2tp.psk === 'string') els.l2tpPsk.value = l2tp.psk;
    }

    syncProtocolFields();
  }

  function fillForm(data) {
    fillConfig(data);
    fillStatus(data);
    showErr(null);
  }

  function formBusy() {
    const active = document.activeElement;
    if (!active) return false;
    return els.form.contains(active);
  }

  function cidrs() {
    return els.cidrs.value
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);
  }

  function secretsBody() {
    const proto = els.protocol.value || 'openvpn';
    const body = {};
    if (proto === 'openvpn' || proto === 'auto') {
      const ovpn = els.ovpnText.value.trim();
      if (ovpn) {
        body.openvpn = {
          ovpn,
          username: els.ovpnUser.value.trim(),
          password: els.ovpnUserPass.value,
          passphrase: els.ovpnPass.value,
        };
      }
    }
    if (proto === 'l2tp' || proto === 'auto') {
      const gw = els.l2tpGw.value.trim();
      const user = els.l2tpUser.value.trim();
      if (gw || user) {
        body.l2tp = {
          gateway: gw,
          user,
          password: els.l2tpPass.value,
          psk: els.l2tpPsk.value,
          ipsec_enabled: true,
        };
      }
    }
    return body;
  }

  function clearSecretFields() {
    // Kept for API compatibility; saved secrets are reloaded via fillConfig.
  }

  async function refresh({ config = false } = {}) {
    const data = await api.get('/api/road');
    if (config) fillForm(data);
    else fillStatus(data);
    return data;
  }

  /** Lightweight update from /api/status.road without touching form inputs. */
  function applyStatusSnippet(road) {
    if (!road || typeof road !== 'object') return;
    if (formBusy()) {
      // Icons only — never reset protocol / fields while typing.
      setIcons(road);
      return;
    }
    setIcons(road);
  }

  els.form.addEventListener('submit', async (e) => {
    e.preventDefault();
    try {
      showErr(null);
      await api.post('/api/road', {
        action: 'configure',
        enabled: els.enabled.checked,
        protocol: els.protocol.value,
        home_cidrs: cidrs(),
        health_url: els.healthUrl.value.trim(),
        openvpn_connection: els.ovpnName.value.trim(),
        l2tp_connection: els.l2tpName.value.trim(),
      });
      const secrets = secretsBody();
      if (secrets.openvpn || secrets.l2tp) {
        await api.post('/api/road', {
          action: 'set_secrets',
          apply: true,
          ...secrets,
        });
      }
      await refresh({ config: true });
    } catch (err) {
      showErr(err.message || String(err));
      // Keep typed fields; still try to reload status without wiping inputs.
      try { await refresh({ config: false }); } catch (_) { /* ignore */ }
    }
  });

  els.enabled.addEventListener('change', async () => {
    try {
      await api.post('/api/road', {
        action: 'configure',
        enabled: els.enabled.checked,
      });
      if (els.enabled.checked) {
        await api.post('/api/road', { action: 'reconcile' });
      }
      await refresh({ config: true });
    } catch (err) {
      showErr(err.message || String(err));
    }
  });

  root.querySelector('#roadCheckPrereq').addEventListener('click', async () => {
    try {
      const data = await api.post('/api/road', { action: 'prereqs' });
      fillPrereq(data);
      showErr(data.ok ? null : (data.hint || 'prerequisites missing'));
    } catch (err) {
      showErr(err.message || String(err));
    }
  });

  root.querySelector('#roadInit').addEventListener('click', async () => {
    const secrets = secretsBody();
    const body = {
      action: 'initialize',
      protocol: els.protocol.value,
      home_cidrs: cidrs(),
      health_url: els.healthUrl.value.trim(),
      openvpn_connection: els.ovpnName.value.trim(),
      l2tp_connection: els.l2tpName.value.trim(),
      ...secrets,
    };
    try {
      showErr(null);
      setIcons({ enabled: true, monitor_state: 'healing', vpn_active: false, at_home: false });
      await api.post('/api/road', body);
      clearSecretFields();
      els.enabled.checked = true;
      await refresh({ config: true });
    } catch (err) {
      showErr(err.message || String(err));
      try { await refresh(); } catch (_) { /* ignore */ }
    }
  });

  root.querySelector('#roadReconcile').addEventListener('click', async () => {
    try {
      setIcons({
        enabled: els.enabled.checked,
        monitor_state: 'healing',
        vpn_active: false,
        at_home: false,
      });
      await api.post('/api/road', { action: 'reconcile' });
      await refresh();
    } catch (err) {
      showErr(err.message || String(err));
    }
  });

  root.querySelector('#roadConnect').addEventListener('click', async () => {
    try {
      setIcons({
        enabled: els.enabled.checked,
        monitor_state: 'healing',
        vpn_active: false,
        at_home: false,
      });
      await api.post('/api/road', {
        action: 'connect',
        protocol: els.protocol.value === 'auto' ? undefined : els.protocol.value,
        force: true,
      });
      await refresh();
    } catch (err) {
      showErr(err.message || String(err));
    }
  });

  root.querySelector('#roadDisconnect').addEventListener('click', async () => {
    try {
      await api.post('/api/road', { action: 'disconnect' });
      await refresh();
    } catch (err) {
      showErr(err.message || String(err));
    }
  });

  const poll = setInterval(() => {
    if (document.hidden || formBusy()) return;
    refresh().catch(() => {});
  }, 8000);
  root.addEventListener('remove', () => clearInterval(poll), { once: true });

  refresh({ config: true }).catch((err) => showErr(err.message || String(err)));
  syncProtocolFields();

  return { refresh, applyStatusSnippet, setIcons };
}
