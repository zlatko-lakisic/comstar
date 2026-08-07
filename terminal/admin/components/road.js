/** Road VPN phone-home panel (ADR 0011). */

export function createRoad(root, { api }) {
  root.innerHTML = `
    <div class="road">
      <div class="road__status" id="roadStatus">
        <div class="road__kv" id="roadKv"></div>
        <p class="road__err mono" id="roadErr" hidden></p>
      </div>
      <form class="road__form" id="roadForm">
        <label class="road__check">
          <input type="checkbox" id="roadEnabled" />
          Auto phone-home when off home subnets
        </label>
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
        <div class="road__row">
          <label class="road__field">
            <span>OpenVPN NM name</span>
            <input id="roadOvpnName" class="mono" type="text" />
          </label>
          <label class="road__field">
            <span>L2TP NM name</span>
            <input id="roadL2tpName" class="mono" type="text" />
          </label>
        </div>
        <div class="road__actions">
          <button type="submit" class="btn" id="roadSave">Save</button>
          <button type="button" class="btn" id="roadReconcile">Reconcile</button>
          <button type="button" class="btn" id="roadConnect">Connect now</button>
          <button type="button" class="btn btn--danger" id="roadDisconnect">Disconnect</button>
        </div>
      </form>
      <details class="road__secrets">
        <summary>VPN credentials (write-only)</summary>
        <div class="road__secrets-body">
          <label class="road__field">
            <span>OpenVPN (.ovpn paste)</span>
            <textarea id="roadOvpnText" class="mono" rows="6" placeholder="client&#10;dev tun&#10;…"></textarea>
          </label>
          <label class="road__field">
            <span>OpenVPN passphrase (optional)</span>
            <input id="roadOvpnPass" type="password" autocomplete="new-password" />
          </label>
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
          <button type="button" class="btn" id="roadSecretsSave">Apply profiles</button>
        </div>
      </details>
    </div>
  `;

  const els = {
    kv: root.querySelector('#roadKv'),
    err: root.querySelector('#roadErr'),
    enabled: root.querySelector('#roadEnabled'),
    protocol: root.querySelector('#roadProtocol'),
    cidrs: root.querySelector('#roadCidrs'),
    ovpnName: root.querySelector('#roadOvpnName'),
    l2tpName: root.querySelector('#roadL2tpName'),
    form: root.querySelector('#roadForm'),
    ovpnText: root.querySelector('#roadOvpnText'),
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

  function fillForm(data) {
    els.enabled.checked = !!data.enabled;
    els.protocol.value = data.protocol || 'openvpn';
    els.cidrs.value = (data.home_cidrs || []).join(', ');
    els.ovpnName.value = data.openvpn_connection || '';
    els.l2tpName.value = data.l2tp_connection || '';

    const rows = [
      ['at home', data.at_home ? 'yes' : 'no'],
      ['matched', (data.matched_addrs || []).join(', ') || '—'],
      ['vpn', data.vpn_active ? `${data.active_protocol} (${data.active_connection})` : 'down'],
      ['ovpn ready', data.openvpn_configured ? 'yes' : 'no'],
      ['l2tp ready', data.l2tp_configured ? 'yes' : 'no'],
      ['last error', data.last_error || '—'],
    ];
    els.kv.innerHTML = rows
      .map(([k, v]) => `<dt>${k}</dt><dd class="mono">${v}</dd>`)
      .join('');
    showErr(null);
  }

  async function refresh() {
    const data = await api.get('/api/road');
    fillForm(data);
    return data;
  }

  els.form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const cidrs = els.cidrs.value
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);
    try {
      await api.post('/api/road', {
        action: 'configure',
        enabled: els.enabled.checked,
        protocol: els.protocol.value,
        home_cidrs: cidrs,
        openvpn_connection: els.ovpnName.value.trim(),
        l2tp_connection: els.l2tpName.value.trim(),
      });
      await refresh();
    } catch (err) {
      showErr(err.message || String(err));
    }
  });

  root.querySelector('#roadReconcile').addEventListener('click', async () => {
    try {
      await api.post('/api/road', { action: 'reconcile' });
      await refresh();
    } catch (err) {
      showErr(err.message || String(err));
    }
  });

  root.querySelector('#roadConnect').addEventListener('click', async () => {
    try {
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

  root.querySelector('#roadSecretsSave').addEventListener('click', async () => {
    const body = { action: 'set_secrets', apply: true };
    const ovpn = els.ovpnText.value.trim();
    if (ovpn) {
      body.openvpn = { ovpn };
      const pass = els.ovpnPass.value;
      if (pass) body.openvpn.passphrase = pass;
    }
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
    if (!body.openvpn && !body.l2tp) {
      showErr('Paste an .ovpn and/or fill L2TP fields');
      return;
    }
    try {
      await api.post('/api/road', body);
      els.ovpnPass.value = '';
      els.l2tpPass.value = '';
      els.l2tpPsk.value = '';
      await refresh();
    } catch (err) {
      showErr(err.message || String(err));
    }
  });

  refresh().catch((err) => showErr(err.message || String(err)));

  return { refresh };
}
