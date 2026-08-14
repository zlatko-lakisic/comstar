/** Dynamic planning + Reach catalog allowlists / provider secrets. */

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function entryLabel(e) {
  return e.label || e.role || e.description || e.id;
}

function shortDesc(e, max = 96) {
  const d = String(e.description || e.role || '').trim();
  if (!d) return '';
  return d.length > max ? `${d.slice(0, max - 1)}…` : d;
}

function catalogById(list) {
  const m = new Map();
  for (const e of list || []) m.set(e.id, e);
  return m;
}

function unionRequiredSecrets(entries, enabledIds) {
  const byName = new Map();
  const byId = catalogById(entries);
  for (const id of enabledIds || []) {
    const e = byId.get(id);
    if (!e || !Array.isArray(e.requiredSecrets)) continue;
    for (const s of e.requiredSecrets) {
      const name = String(s.name || '').trim();
      if (!name) continue;
      const prev = byName.get(name);
      byName.set(name, {
        name,
        label: s.label || prev?.label || name,
        required: !!(s.required || prev?.required),
      });
    }
  }
  return [...byName.values()].sort((a, b) => a.name.localeCompare(b.name));
}

function matchesFilter(e, q) {
  if (!q) return true;
  const hay = `${e.id} ${entryLabel(e)} ${e.description || ''} ${e.provider || ''} ${e.role || ''}`.toLowerCase();
  return hay.includes(q);
}

/** Merge status agents + AO catalog (live+stock) + enabled ids into one list. */
function buildAgentPool(snapshot, draftIds) {
  const byId = new Map();
  const catalogAgents = snapshot.catalog?.agents || [];
  const liveIds = new Set(
    catalogAgents.filter((a) => a.available || a.onAo).map((a) => a.id),
  );

  function upsert(raw, source) {
    if (!raw?.id) return;
    const prev = byId.get(raw.id) || {};
    const onAo = !!(raw.onAo || raw.available || liveIds.has(raw.id) || prev.onAo);
    byId.set(raw.id, {
      id: raw.id,
      label: raw.label || prev.label || entryLabel(raw),
      description: raw.description || prev.description || '',
      provider: raw.provider || prev.provider || raw.type || '',
      role: raw.role || prev.role || '',
      model: raw.model || prev.model || '',
      requiredSecrets: raw.requiredSecrets || prev.requiredSecrets || [],
      ready: raw.ready ?? prev.ready,
      onAo,
      available: onAo,
      source: raw.source || prev.source || source,
    });
  }

  for (const a of catalogAgents) upsert(a, a.source || 'catalog');
  for (const a of snapshot.agents || []) upsert(a, 'curated');
  for (const id of draftIds || []) {
    if (!byId.has(id)) upsert({ id, label: id, onAo: liveIds.has(id) }, 'custom');
  }

  return [...byId.values()].sort((a, b) => {
    // Available first, then alphabetical.
    if (!!a.onAo !== !!b.onAo) return a.onAo ? -1 : 1;
    return a.id.localeCompare(b.id);
  });
}

function buildPool(catalogList, draftIds) {
  const byId = new Map();
  for (const e of catalogList || []) {
    if (!e?.id) continue;
    byId.set(e.id, { ...e, label: entryLabel(e) });
  }
  for (const id of draftIds || []) {
    if (!byId.has(id)) byId.set(id, { id, label: id, description: '' });
  }
  return [...byId.values()].sort((a, b) => a.id.localeCompare(b.id));
}

export function createAgents(root, { api, onStatus } = {}) {
  root.innerHTML = `
    <div class="panel">
      <div class="panel__head">
        <h2>Agents</h2>
        <p class="muted">Toggle the full catalog (and curated COMSTAR agents even if AO is not advertising them). Filter to find entries. Save, then Apply to reopen the session.</p>
      </div>
      <div class="agents-status" id="agentsStatus"></div>
      <div class="agents-grid" id="agentsBody">Loading…</div>
      <div class="agents-actions" id="agentsActions" style="display:none">
        <button type="button" class="btn" id="agentsSave">Save</button>
        <button type="button" class="btn btn--ghost" id="agentsApply">Apply (reopen session)</button>
        <span class="muted" id="agentsMsg"></span>
      </div>
    </div>
  `;

  const body = root.querySelector('#agentsBody');
  const actions = root.querySelector('#agentsActions');
  const statusEl = root.querySelector('#agentsStatus');
  const msg = root.querySelector('#agentsMsg');

  let snapshot = null;
  let draftAgents = [];
  let draftMcps = [];
  let draftSkills = [];
  let secretDraft = {};
  let testedOk = new Set();
  const filters = { agents: '', mcps: '', skills: '', harnesses: '' };

  function setMsg(t, ok) {
    msg.textContent = t || '';
    msg.style.color = ok === false ? 'var(--danger, #c44)' : '';
  }

  function draftFor(kind) {
    if (kind === 'agents') return draftAgents;
    if (kind === 'mcps') return draftMcps;
    return draftSkills;
  }

  function setDraft(kind, ids) {
    if (kind === 'agents') draftAgents = ids;
    else if (kind === 'mcps') draftMcps = ids;
    else draftSkills = ids;
  }

  function renderPicker(kind, pool, opts = {}) {
    const enabled = new Set(draftFor(kind));
    const q = (filters[kind] || '').trim().toLowerCase();
    const filtered = pool.filter((e) => matchesFilter(e, q));
    const enabledCount = pool.filter((e) => enabled.has(e.id)).length;
    const noun = kind === 'agents' ? 'agent' : kind === 'mcps' ? 'MCP' : 'skill';

    const rows = filtered
      .map((e) => {
        const on = enabled.has(e.id);
        const ready = e.ready !== false;
        const desc = shortDesc(e);
        const badges = [];
        if (opts.showAoBadge) {
          badges.push(
            e.onAo || e.available
              ? '<span class="agents-badge is-on-ao">available on AO</span>'
              : '<span class="agents-badge is-off-ao">stock (not advertised)</span>',
          );
        }
        if (on && !ready) badges.push('<span class="agents-badge is-blocked">needs secret</span>');
        if (on && ready) badges.push('<span class="agents-badge is-ready">ready</span>');
        return `<label class="agents-row ${on ? 'is-on' : ''} ${ready ? '' : 'is-blocked'}">
          <input type="checkbox" data-toggle="${escapeHtml(kind)}" data-id="${escapeHtml(e.id)}" ${on ? 'checked' : ''} />
          <span class="agents-row__main">
            <span class="agents-row__title">
              <code class="agents-row__id">${escapeHtml(e.id)}</code>
              <span class="agents-row__label">${escapeHtml(e.label || e.id)}</span>
            </span>
            ${desc ? `<span class="agents-row__desc" title="${escapeHtml(e.description || desc)}">${escapeHtml(desc)}</span>` : ''}
            <span class="agents-row__badges">${badges.join('')}${e.provider ? `<span class="agents-badge is-provider">${escapeHtml(e.provider)}</span>` : ''}</span>
          </span>
        </label>`;
      })
      .join('');

    return `<div class="agents-picker" data-picker="${escapeHtml(kind)}">
      <div class="agents-picker__bar">
        <input type="search" class="agents-filter" data-filter="${escapeHtml(kind)}"
          placeholder="Filter ${noun}s…" value="${escapeHtml(filters[kind] || '')}" />
        <span class="muted agents-picker__count">${enabledCount} enabled · ${filtered.length}/${pool.length} shown</span>
      </div>
      <div class="agents-picker__list" role="list">
        ${rows || `<p class="muted agents-empty">No ${noun}s match.</p>`}
      </div>
      ${
        opts.allowCustom
          ? `<div class="agents-custom">
              <input type="text" class="agents-custom__input" data-custom="${escapeHtml(kind)}"
                placeholder="Or enable by id (even if missing from AO)…" spellcheck="false" />
              <button type="button" class="btn btn--ghost" data-custom-add="${escapeHtml(kind)}">Enable id</button>
            </div>`
          : ''
      }
    </div>`;
  }

  function renderHarnesses(list) {
    if (!list?.length) return `<p class="muted">No harnesses in catalog.</p>`;
    const q = (filters.harnesses || '').trim().toLowerCase();
    const filtered = list.filter((h) => matchesFilter(h, q));
    return `<div class="agents-picker" data-picker="harnesses">
      <div class="agents-picker__bar">
        <input type="search" class="agents-filter" data-filter="harnesses"
          placeholder="Filter harnesses…" value="${escapeHtml(filters.harnesses || '')}" />
        <span class="muted agents-picker__count">${filtered.length}/${list.length} shown</span>
      </div>
      <ul class="agents-harness-list">${filtered
        .map((h) => {
          const linked = (h.agentProviderIds || []).join(', ') || '—';
          return `<li class="agents-harness">
            <code>${escapeHtml(h.id)}</code>
            <span class="muted">${escapeHtml(shortDesc(h, 140) || h.description || '')}</span>
            <span class="muted">agents: ${escapeHtml(linked)}</span>
          </li>`;
        })
        .join('')}</ul>
    </div>`;
  }

  function renderSecrets(required, secrets) {
    if (!required.length) {
      return `<p class="muted">No secrets required by the current enable lists.</p>`;
    }
    return required
      .map((s) => {
        const name = s.name;
        const meta = secrets?.env?.[name] || secrets?.[name] || {};
        const present = !!(meta.present || meta.configured);
        const draft = secretDraft[name] || '';
        const probeable = name === 'OPENAI_API_KEY' || name === 'ANTHROPIC_API_KEY';
        const checked = testedOk.has(name) || meta.valid === true ? 'checked' : '';
        return `<div class="agents-secret" data-env="${escapeHtml(name)}">
          <label>${escapeHtml(s.label || meta.label || name)}${s.required ? ' *' : ''}
            <input type="password" autocomplete="off" data-secret="${escapeHtml(name)}"
              placeholder="${present ? '•••••••• (saved — leave blank to keep)' : 'paste secret'}"
              value="${escapeHtml(draft)}" />
          </label>
          <span class="agents-secret__meta">
            <code>${escapeHtml(name)}</code>
            <span class="muted">${present ? 'saved' : 'missing'}</span>
            ${
              probeable
                ? `<label class="agents-valid"><input type="checkbox" data-valid="${escapeHtml(name)}" ${checked} disabled /> valid</label>
                   <button type="button" class="btn btn--ghost" data-test="${escapeHtml(name)}">Test</button>`
                : ''
            }
            ${present ? `<button type="button" class="btn btn--ghost" data-clear="${escapeHtml(name)}">Clear</button>` : ''}
          </span>
        </div>`;
      })
      .join('');
  }

  function render() {
    if (!snapshot) return;
    const cat = snapshot.catalog || {};
    const agentsPool = buildAgentPool(snapshot, draftAgents);
    const mcpsPool = buildPool(cat.mcps || [], draftMcps);
    const skillsPool = buildPool(cat.skills || [], draftSkills);
    const harnesses = cat.harnesses || [];
    const required = unionRequiredSecrets(
      [...agentsPool, ...mcpsPool, ...skillsPool],
      [...draftAgents, ...draftMcps, ...draftSkills],
    );

    statusEl.innerHTML = `
      <div class="agents-status-row">
        <span>Session agents: <strong>${(snapshot.session_allowed_agent_ids || []).length}</strong></span>
        <span>MCPs: <strong>${(snapshot.session_allowed_mcp_ids || []).length}</strong></span>
        <span>Skills: <strong>${(snapshot.session_allowed_skill_ids || []).length}</strong></span>
        <span class="muted">${snapshot.session_open ? 'session open' : 'session closed'}</span>
        ${cat.ok === false ? `<span class="agents-warn">live catalog: ${escapeHtml(cat.error || 'failed')}</span>` : ''}
        <span class="muted">AO live ${Number(cat.live_agent_count) || 0} · stock ${Number(cat.stock_agent_count) || agentsPool.length}</span>
      </div>`;

    body.innerHTML = `
      <section class="agents-section">
        <h3>Agents</h3>
        <p class="muted">Full AO stock pack (${agentsPool.length} agents) plus whatever Ada is advertising live. Enable any id — Apply sends allowlists + secrets even when AO is not currently advertising that provider.</p>
        ${renderPicker('agents', agentsPool, { showAoBadge: true, allowCustom: true })}
      </section>
      <section class="agents-section">
        <h3>MCPs</h3>
        ${renderPicker('mcps', mcpsPool, { allowCustom: true })}
      </section>
      <section class="agents-section">
        <h3>Skills</h3>
        ${renderPicker('skills', skillsPool, { allowCustom: true })}
      </section>
      <section class="agents-section">
        <h3>Harnesses</h3>
        <p class="muted">Informational — selected via agent harnessProfile on AO, not a session allowlist.</p>
        ${renderHarnesses(harnesses)}
      </section>
      <section class="agents-section">
        <h3>Secrets</h3>
        ${renderSecrets(required, snapshot.secrets)}
      </section>
      <section class="agents-section">
        <label class="agents-check"><input type="checkbox" id="dynEnabled" ${snapshot.dynamic_planning || snapshot.enabled ? 'checked' : ''} /> Dynamic planning enabled</label>
        <p class="muted">AO dynamic timeout: <strong>${Number(snapshot.timeout_seconds) || 300}s</strong> (from comstar.yaml)</p>
      </section>
    `;
    actions.style.display = '';
    wire();
  }

  function wire() {
    body.querySelectorAll('[data-filter]').forEach((inp) => {
      inp.addEventListener('input', () => {
        const kind = inp.getAttribute('data-filter');
        filters[kind] = inp.value;
        const active = document.activeElement === inp;
        const start = inp.selectionStart;
        render();
        if (active) {
          const next = body.querySelector(`[data-filter="${CSS.escape(kind)}"]`);
          if (next) {
            next.focus();
            try {
              next.setSelectionRange(start, start);
            } catch {
              /* ignore */
            }
          }
        }
      });
    });

    body.querySelectorAll('[data-toggle]').forEach((box) => {
      box.addEventListener('change', () => {
        const kind = box.getAttribute('data-toggle');
        const id = box.getAttribute('data-id');
        const cur = new Set(draftFor(kind));
        if (box.checked) cur.add(id);
        else cur.delete(id);
        setDraft(kind, [...cur]);
        // Soft update counts without full re-filter jump: re-render is fine.
        render();
      });
    });

    body.querySelectorAll('[data-custom-add]').forEach((btn) => {
      btn.addEventListener('click', () => {
        const kind = btn.getAttribute('data-custom-add');
        const inp = body.querySelector(`[data-custom="${CSS.escape(kind)}"]`);
        const id = (inp?.value || '').trim();
        if (!id) return;
        const cur = draftFor(kind);
        if (!cur.includes(id)) setDraft(kind, [...cur, id]);
        if (inp) inp.value = '';
        render();
      });
    });

    body.querySelectorAll('[data-secret]').forEach((inp) => {
      inp.addEventListener('input', () => {
        const name = inp.getAttribute('data-secret');
        secretDraft[name] = inp.value;
        testedOk.delete(name);
        const box = body.querySelector(`[data-valid="${CSS.escape(name)}"]`);
        if (box) box.checked = false;
      });
    });

    body.querySelectorAll('[data-test]').forEach((btn) => {
      btn.addEventListener('click', async () => {
        const name = btn.getAttribute('data-test');
        const inp = body.querySelector(`[data-secret="${CSS.escape(name)}"]`);
        const value = (inp?.value || '').trim();
        if (!value) {
          setMsg('Paste a key before testing.', false);
          return;
        }
        btn.disabled = true;
        setMsg(`Testing ${name}…`);
        try {
          const res = await api.post('/api/agents', {
            action: 'test_secret',
            env: name,
            value,
          });
          const box = body.querySelector(`[data-valid="${CSS.escape(name)}"]`);
          if (res.ok) {
            testedOk.add(name);
            if (box) box.checked = true;
            setMsg(`${name} looks valid.`, true);
          } else {
            testedOk.delete(name);
            if (box) box.checked = false;
            setMsg(res.error || 'Invalid key', false);
          }
        } catch (e) {
          setMsg(String(e.message || e), false);
        } finally {
          btn.disabled = false;
        }
      });
    });

    body.querySelectorAll('[data-clear]').forEach((btn) => {
      btn.addEventListener('click', async () => {
        const name = btn.getAttribute('data-clear');
        try {
          await api.post('/api/agents', { action: 'clear_secret', env: name });
          delete secretDraft[name];
          testedOk.delete(name);
          await refresh();
          setMsg(`Cleared ${name}.`, true);
        } catch (e) {
          setMsg(String(e.message || e), false);
        }
      });
    });
  }

  async function collectAndSave(apply) {
    const enabled = !!body.querySelector('#dynEnabled')?.checked;
    const env = {};
    for (const [k, v] of Object.entries(secretDraft)) {
      if (String(v || '').trim()) env[k] = String(v).trim();
    }
    if (Object.keys(env).length) {
      await api.post('/api/agents', { action: 'set_secrets', env });
    }
    const res = await api.post('/api/agents', {
      action: apply ? 'apply' : 'configure',
      enabled,
      dynamic_planning: enabled,
      enabled_agent_ids: draftAgents,
      enabled_mcp_ids: draftMcps,
      enabled_skill_ids: draftSkills,
    });
    secretDraft = {};
    testedOk = new Set();
    return res;
  }

  root.querySelector('#agentsSave').addEventListener('click', async () => {
    setMsg('Saving…');
    try {
      await collectAndSave(false);
      await refresh();
      setMsg('Saved.', true);
    } catch (e) {
      setMsg(String(e.message || e), false);
    }
  });

  root.querySelector('#agentsApply').addEventListener('click', async () => {
    setMsg('Applying (reopening session)…');
    try {
      const res = await collectAndSave(true);
      await refresh();
      setMsg(
        res.session_reopened || res.apply?.refreshed
          ? 'Applied — session reopened.'
          : 'Saved (session reopen skipped).',
        true,
      );
    } catch (e) {
      setMsg(String(e.message || e), false);
    }
  });

  async function refresh() {
    const data = await api.get('/api/agents');
    snapshot = data;
    draftAgents = [...(data.enabled_agent_ids || [])];
    draftMcps = [...(data.enabled_mcp_ids || [])];
    draftSkills = [...(data.enabled_skill_ids || [])];
    const readyCount = (data.agents || []).filter((a) => a.ready).length;
    onStatus?.({
      dynamic_planning: !!(data.dynamic_planning ?? data.enabled),
      needs_refresh: !!data.apply?.needs_session_refresh,
      ready_count: readyCount,
    });
    render();
  }

  refresh().catch((e) => {
    body.textContent = `Failed to load agents: ${e.message || e}`;
  });

  return { refresh };
}
