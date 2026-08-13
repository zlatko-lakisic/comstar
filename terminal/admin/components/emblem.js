import { mountEmblem } from '/kiosk/emblem.js';
import { createAoActivity } from '/kiosk/ao_activity.js';

/** Thin wrapper: dashboard emblem driven by polled bridge state. */
export function createRailEmblem(container, { activityRoot } = {}) {
  const emblem = mountEmblem(container, {
    bloom: 6,
    scale: 0.72,
    maxFps: 24,
    bg: true,
  });
  const activity = activityRoot ? createAoActivity(activityRoot) : null;

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

  let lastProgressActive = false;

  return {
    apply(status, meta = {}) {
      const name = mapState(status, meta);
      emblem.setState(name);
      const p = status?.ao_progress;
      const progressActive = !!(p && typeof p === 'object' && p.active);
      const thinking = !!(status?.thinking || p?.processing || progressActive);
      emblem.setThinking(thinking);
      if (activity) {
        if (p && typeof p === 'object') {
          activity.apply(p);
          lastProgressActive = progressActive;
        } else if (lastProgressActive) {
          activity.apply({ active: false });
          lastProgressActive = false;
        }
      }
      return name;
    },
    setUnreachable() {
      emblem.setState('unreachable');
      emblem.setThinking(false);
      lastProgressActive = false;
      activity?.clearNow();
    },
    destroy() { emblem.destroy(); },
  };
}

export function createGateEmblem(container) {
  return mountEmblem(container, { bloom: 4, scale: 0.7, maxFps: 12, bg: true });
}
