/** Durations, relative time, bytes. No em dashes. */

export function fmtMs(ms) {
  if (ms == null || !Number.isFinite(ms)) return '—';
  if (ms < 1000) return `${Math.round(ms)}ms`;
  return `${(ms / 1000).toFixed(1)}s`;
}

export function fmtAge(seconds) {
  if (seconds == null || !Number.isFinite(seconds)) return '—';
  if (seconds < 3) return `updated ${seconds.toFixed(1)}s ago`;
  if (seconds < 10) return `updated ${seconds.toFixed(0)}s ago`;
  return `STALE ${Math.round(seconds)}s`;
}

export function fmtNoContact(seconds) {
  return `NO CONTACT ${Math.round(seconds)}s`;
}

export function fmtUptime(seconds) {
  if (seconds == null || !Number.isFinite(seconds)) return '—';
  const s = Math.max(0, Math.floor(seconds));
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (d > 0) return `${d}d ${String(h).padStart(2, '0')}h`;
  return `${h}h ${String(m).padStart(2, '0')}m`;
}

export function fmtClock(date = new Date()) {
  return date.toLocaleTimeString(undefined, { hour12: false });
}

export function fmtMem(percent, totalHintGb) {
  if (percent == null) return '—';
  if (totalHintGb) {
    const used = (percent / 100) * totalHintGb;
    return `${used.toFixed(1)} / ${totalHintGb.toFixed(1)} GB`;
  }
  return `${Number(percent).toFixed(0)}%`;
}

export function pct(n) {
  if (n == null || !Number.isFinite(Number(n))) return '—';
  return `${Number(n).toFixed(0)}%`;
}
