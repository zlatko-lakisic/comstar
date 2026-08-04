import { mountEmblem } from '/kiosk/emblem.js';

/** Thin wrapper: dashboard emblem driven by polled bridge state. */
export function createRailEmblem(container) {
  const emblem = mountEmblem(container, {
    bloom: 6,
    scale: 0.72,
    maxFps: 24,
    bg: true,
  });

  const DASHBOARD_AMBIENT = 'ambient';

  function mapState(status, { contactOk, degraded }) {
    if (!contactOk) return 'unreachable';
    if (degraded) return 'degraded';
    const s = status?.state || DASHBOARD_AMBIENT;
    if (s === 'sleeping' || s === 'listening' || s === 'responding' ||
        s === 'engaged' || s === 'noticed' || s === 'ambient') {
      return s;
    }
    return DASHBOARD_AMBIENT;
  }

  return {
    apply(status, meta = {}) {
      const name = mapState(status, meta);
      emblem.setState(name);
      return name;
    },
    setUnreachable() { emblem.setState('unreachable'); },
    destroy() { emblem.destroy(); },
  };
}

export function createGateEmblem(container) {
  return mountEmblem(container, { bloom: 4, scale: 0.7, maxFps: 12, bg: true });
}
