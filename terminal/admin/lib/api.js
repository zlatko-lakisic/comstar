/** Fetch wrapper: token header, backoff, 401 gate. */

const BASE = '/admin';

export function createApi({ getToken, setToken, onUnauthorized }) {
  let misses = 0;

  function headers(json = false) {
    const h = {};
    if (json) h['Content-Type'] = 'application/json';
    const token = getToken();
    if (token) h['X-Comstar-Lan-Token'] = token;
    return h;
  }

  function withToken(path) {
    const full = path.startsWith('/') ? `${BASE}${path}` : `${BASE}/${path}`;
    const token = getToken();
    if (!token) return full;
    const u = new URL(full, location.origin);
    if (!u.searchParams.has('token')) u.searchParams.set('token', token);
    return u.pathname + u.search;
  }

  async function request(path, opts = {}) {
    const res = await fetch(withToken(path), {
      ...opts,
      headers: { ...headers(!!opts.body), ...(opts.headers || {}) },
    });
    if (res.status === 401) {
      onUnauthorized?.();
      const err = new Error('unauthorized');
      err.code = 401;
      throw err;
    }
    const text = await res.text();
    let data = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = { raw: text }; }
    if (!res.ok) {
      const err = new Error((data && (data.error || data.hint)) || `HTTP ${res.status}`);
      err.code = res.status;
      err.data = data;
      throw err;
    }
    return data;
  }

  function nextBackoffMs() {
    misses = Math.min(misses + 1, 4);
    const base = Math.min(15000, 2000 * (2 ** (misses - 1)));
    const jitter = base * (0.15 * Math.random());
    return base + jitter;
  }

  function resetBackoff() { misses = 0; }

  return {
    get: (path) => request(path),
    post: (path, body) => request(path, { method: 'POST', body: JSON.stringify(body || {}) }),
    url: withToken,
    authHeaders: () => headers(false),
    nextBackoffMs,
    resetBackoff,
    get misses() { return misses; },
  };
}
