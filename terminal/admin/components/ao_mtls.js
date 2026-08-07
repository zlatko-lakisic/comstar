/** AO Reach mTLS pairing (ADR 0013). */

export function createAoMtls(root, { api }) {
  root.innerHTML = `
    <div class="ao-mtls">
      <p class="ao-mtls__err mono" id="aoMtlsErr" hidden></p>
      <div class="ao-mtls__banner" id="aoMtlsBanner"></div>
      <div class="ao-mtls__kv" id="aoMtlsKv"></div>

      <section class="ao-mtls__step">
        <h3 class="ao-mtls__step-title">Pair with Ada</h3>
        <p class="ao-mtls__hint">
          Mint a one-time token on Ada:
          <span class="mono">python -m orchestration.serve.mtls mint-token --client-name comstar-ai</span>
        </p>
        <form class="ao-mtls__form" id="aoMtlsForm">
          <label class="ao-mtls__field">
            <span>Client name (CN)</span>
            <input id="aoMtlsClientName" class="mono" type="text" autocomplete="off" placeholder="comstar-ai" />
          </label>
          <label class="ao-mtls__field">
            <span>Enroll token</span>
            <input id="aoMtlsToken" class="mono" type="password" autocomplete="off" />
          </label>
          <div class="ao-mtls__row">
            <button type="submit" class="btn btn--primary" id="aoMtlsEnroll">Enroll / re-pair</button>
            <button type="button" class="btn" id="aoMtlsProbe">Probe /health</button>
            <button type="button" class="btn" id="aoMtlsClear">Clear local certs</button>
            <button type="button" class="btn" id="aoMtlsRefresh">Refresh</button>
          </div>
        </form>
      </section>
    </div>
  `;

  const els = {
    err: root.querySelector('#aoMtlsErr'),
    banner: root.querySelector('#aoMtlsBanner'),
    kv: root.querySelector('#aoMtlsKv'),
    clientName: root.querySelector('#aoMtlsClientName'),
    token: root.querySelector('#aoMtlsToken'),
    form: root.querySelector('#aoMtlsForm'),
    probe: root.querySelector('#aoMtlsProbe'),
    clear: root.querySelector('#aoMtlsClear'),
    refresh: root.querySelector('#aoMtlsRefresh'),
  };

  let busy = false;
  let last = null;

  function showErr(msg) {
    if (!msg) {
      els.err.hidden = true;
      els.err.textContent = '';
      return;
    }
    els.err.hidden = false;
    els.err.textContent = msg;
  }

  function render(data) {
    last = data;
    const enabled = !!data.enabled;
    const paired = !!data.paired;
    els.banner.className = 'ao-mtls__banner';
    if (!enabled) {
      els.banner.classList.add('is-off');
      els.banner.textContent =
        'mTLS disabled in config (orchestration.mtls.enabled). Enroll still works; session will not use certs until enabled.';
    } else if (paired) {
      els.banner.classList.add('is-up');
      els.banner.textContent = 'Paired — client cert on disk. Next session open will use mTLS.';
    } else {
      els.banner.classList.add('is-down');
      els.banner.textContent = 'Not paired — enroll with an Ada mint-token.';
    }

    const rows = [
      ['Base URL', data.base_url || '—'],
      ['Material dir', data.material_dir || '—'],
      ['Client name', data.client_name || '—'],
      ['Subject', data.subject || '—'],
      ['Enrolled', data.enrolled_at || '—'],
      [
        'Expires',
        data.expires_at != null
          ? new Date(Number(data.expires_at) * 1000).toISOString()
          : '—',
      ],
      ['openssl', data.openssl_ok ? 'ok' : 'missing'],
    ];
    els.kv.innerHTML = rows
      .map(
        ([k, v]) =>
          `<div class="ao-mtls__kv-row"><span>${k}</span><span class="mono">${escapeHtml(
            String(v),
          )}</span></div>`,
      )
      .join('');

    if (data.client_name && !els.clientName.value) {
      els.clientName.value = data.client_name;
    }
    if (data.last_error) showErr(data.last_error);
  }

  function escapeHtml(s) {
    return s
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  async function refresh() {
    showErr('');
    try {
      const data = await api.get('/admin/api/ao_mtls');
      render(data);
    } catch (e) {
      showErr(e.message || String(e));
    }
  }

  async function post(body) {
    if (busy) return;
    busy = true;
    showErr('');
    try {
      const data = await api.post('/admin/api/ao_mtls', body);
      if (data.ok === false) {
        showErr(data.error || 'request failed');
      }
      render(data);
      return data;
    } catch (e) {
      showErr(e.message || String(e));
      return null;
    } finally {
      busy = false;
    }
  }

  els.form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const token = (els.token.value || '').trim();
    if (!token) {
      showErr('enroll token required');
      return;
    }
    const clientName = (els.clientName.value || '').trim();
    const data = await post({
      action: 'enroll',
      enroll_token: token,
      ...(clientName ? { client_name: clientName } : {}),
    });
    if (data?.ok) els.token.value = '';
  });

  els.probe.addEventListener('click', () => post({ action: 'probe' }));
  els.clear.addEventListener('click', async () => {
    if (!confirm('Delete local AO client certs? Ada will still have the old cert until it expires.')) {
      return;
    }
    await post({ action: 'clear' });
  });
  els.refresh.addEventListener('click', () => refresh());

  refresh();

  return {
    onShow: () => refresh(),
    refresh,
  };
}
