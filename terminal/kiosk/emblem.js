/**
 * Pure COMSTAR emblem renderer. State in, SVG out. No audio, no WebSocket.
 *
 * Used by the hallway kiosk (via avatar.js) and the admin dashboard.
 */

import { resolveEmblem } from './presets.js';

/** Kiosk / panel state params (spin, opacity, scale, sway). */
export const STATE_PARAMS = {
  ambient:    { spin: 2,  op: 0.70, sc: 0.92, sway: 0.40 },
  sleeping:   { spin: 1,  op: 0.22, sc: 0.88, sway: 0.30 },
  noticed:    { spin: 18, op: 0.80, sc: 0.94, sway: 0.35 },
  engaged:    { spin: 0,  op: 1.00, sc: 1.00, sway: 0.12 },
  listening:  { spin: 8,  op: 1.00, sc: 1.00, sway: 0.12 },
  responding: { spin: 14, op: 1.00, sc: 1.00, sway: 0.12 },
  // Reply mood overlays (Phase 2 — speak.mood / config.mood).
  neutral:      { spin: 10, op: 1.00, sc: 1.00, sway: 0.12 },
  happy:        { spin: 22, op: 1.00, sc: 1.06, sway: 0.18 },
  concerned:    { spin: 4,  op: 0.88, sc: 0.96, sway: 0.08 },
  thinking:     { spin: 12, op: 0.95, sc: 1.00, sway: 0.22 },
  celebratory:  { spin: 36, op: 1.00, sc: 1.10, sway: 0.28 },
  // Dashboard-only instruments (ops console).
  degraded:   { spin: 6,  op: 0.70, sc: 0.94, sway: 0.18, amber: true },
  unreachable:{ spin: 0,  op: 0.28, sc: 0.88, sway: 0,    frozen: true, ring: true },
};

const STATE_DAMPING = 3.5;
const OPACITY_DAMPING = 3.2;
const METER_CIRCUM = 2 * Math.PI * 226;
const AMBER = '#F0A202';
const CYAN = '#7fc4ff';

/**
 * @param {HTMLElement} container
 * @param {{ emblem?: string, bloom?: number, scale?: number, maxFps?: number, bg?: boolean }} [opts]
 * @returns {{ setState: Function, setThinking: Function, setMicLevel: Function, setAmplitude: Function, destroy: Function, state: string }}
 */
export function mountEmblem(container, opts = {}) {
  const bloom = opts.bloom ?? 0;
  const emblemScale = opts.emblemScale ?? opts.scale ?? 0.62;
  const maxFps = Math.max(8, Math.min(60, opts.maxFps ?? 24));
  const fitMaxPx = (() => {
    const n = Number(opts.fitMaxPx ?? opts.maxSize ?? 720);
    return Number.isFinite(n) ? Math.max(200, Math.min(4096, n)) : 720;
  })();
  const fitFill = (() => {
    const n = Number(opts.fitFill ?? 0.92);
    return Number.isFinite(n) ? Math.max(0.5, Math.min(1, n)) : 0.92;
  })();
  const showBg = opts.bg !== false;
  const emblem = resolveEmblem(opts.emblem ?? 'starburst');

  let state = 'ambient';
  let thinking = false;
  let micLevel = 0;
  let amplitude = 0;
  let cur = { ...STATE_PARAMS.ambient };
  let spinCore = 0;
  let spinHalo = 0;
  let t = 0;
  let last = performance.now();
  let raf = 0;
  let stutterT = 0;

  const uid = `em${(mountEmblem._n = (mountEmblem._n || 0) + 1)}`;
  const ns = 'http://www.w3.org/2000/svg';

  container.innerHTML = '';
  Object.assign(container.style, {
    position: 'relative',
    overflow: 'hidden',
    ...(showBg ? {
      background:
        'radial-gradient(ellipse 80% 55% at 50% 48%, rgba(61,220,255,0.08), transparent 72%), #06080B',
    } : {}),
  });

  const glow = document.createElement('div');
  Object.assign(glow.style, {
    position: 'absolute',
    left: '50%',
    top: '50%',
    transform: 'translate(-50%, -50%)',
    aspectRatio: '1',
    background:
      'radial-gradient(circle, rgba(61,220,255,0.12) 0%, rgba(61,220,255,0.04) 42%, transparent 68%)',
    pointerEvents: 'none',
    zIndex: '0',
  });
  container.appendChild(glow);

  const svg = document.createElementNS(ns, 'svg');
  svg.setAttribute('viewBox', '0 0 512 512');
  svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
  Object.assign(svg.style, {
    position: 'absolute',
    display: 'block',
    left: '50%',
    top: '50%',
    transform: 'translate(-50%, -50%)',
    maxWidth: '100%',
    maxHeight: '100%',
    zIndex: '1',
  });
  svg.innerHTML = `
    <title>COMSTAR</title>
    <defs>
      <filter id="${uid}-bloom" x="-60%" y="-60%" width="220%" height="220%"
              color-interpolation-filters="sRGB">
        <feGaussianBlur stdDeviation="${bloom}"/>
      </filter>
    </defs>
    <g class="cs-shift" transform="translate(256,256)">
      <circle class="cs-outer-ring" r="240" fill="none" stroke="${AMBER}"
              stroke-width="3" opacity="0"/>
      <g class="cs-halo">${emblem}</g>
      <g class="cs-core">${emblem}</g>
      <circle class="cs-meter" r="226" fill="none" stroke="${CYAN}"
              stroke-width="6" stroke-linecap="round"
              stroke-dasharray="0 ${METER_CIRCUM}"
              transform="rotate(-90)" opacity="0"/>
    </g>`;
  container.appendChild(svg);

  const shift = svg.querySelector('.cs-shift');
  const halo = svg.querySelector('.cs-halo');
  const core = svg.querySelector('.cs-core');
  const meter = svg.querySelector('.cs-meter');
  const outerRing = svg.querySelector('.cs-outer-ring');
  if (bloom > 0) {
    halo.setAttribute('filter', `url(#${uid}-bloom)`);
  } else {
    halo.style.display = 'none';
  }
  const coreRings = core.querySelector('.cs-rings');
  const haloRings = halo.querySelector('.cs-rings');
  const bars = [...core.querySelectorAll('.cs-bars rect')];

  function fitSquare() {
    const w = container.clientWidth || 0;
    const h = container.clientHeight || 0;
    if (w < 1 || h < 1) return;
    const short = Math.min(w, h);
    const s = Math.max(1, Math.round(Math.min(short * fitFill, fitMaxPx)));
    svg.style.width = `${s}px`;
    svg.style.height = `${s}px`;
    const g = Math.round(s * 1.4);
    glow.style.width = `${g}px`;
    glow.style.height = `${g}px`;
  }
  fitSquare();
  const ro = typeof ResizeObserver !== 'undefined'
    ? new ResizeObserver(fitSquare)
    : null;
  if (ro) ro.observe(container);

  function paramsFor(name) {
    return STATE_PARAMS[name] || STATE_PARAMS.ambient;
  }

  function frame(now) {
    raf = 0;
    const target = paramsFor(state);
    const frozen = !!target.frozen;
    const minDt = 1 / (frozen ? 8 : maxFps);
    const elapsed = (now - last) / 1000;
    if (elapsed < minDt * 0.92) {
      raf = requestAnimationFrame(frame);
      return;
    }
    const dt = Math.min(elapsed, 0.1);
    last = now;
    t += dt;

    if (!frozen) {
      const k = 1 - Math.exp(-STATE_DAMPING * dt);
      const kOp = 1 - Math.exp(-OPACITY_DAMPING * dt);
      for (const key of Object.keys(target)) {
        if (key === 'amber' || key === 'frozen' || key === 'ring') continue;
        const damp = key === 'op' ? kOp : k;
        cur[key] += (target[key] - cur[key]) * damp;
      }
    } else {
      cur.op += (target.op - cur.op) * 0.2;
      cur.sc += (target.sc - cur.sc) * 0.2;
      cur.spin = 0;
      cur.sway = 0;
    }

    // Degraded: intentional stutter every ~2s.
    let spinMul = 1;
    if (target.amber) {
      stutterT += dt;
      if ((stutterT % 2) > 1.7) spinMul = 0.15;
    }

    amplitude *= state === 'responding' ? 0.98 : 0.9;
    if (state === 'responding' && amplitude < 0.15) {
      amplitude = 0.2 + Math.sin(t * 8) * 0.15;
    }

    const breathe = frozen
      ? 1
      : 1 + Math.sin(t * 0.4) * 0.03 * cur.sway;
    const base = cur.sc * breathe;
    const mic = state === 'listening' ? micLevel : 0;

    if (!frozen) {
      spinCore += cur.spin * dt * spinMul;
    }
    if (coreRings) {
      coreRings.setAttribute('transform', `rotate(${spinCore.toFixed(2)})`);
    }
    if (bloom > 0 && haloRings && !frozen) {
      spinHalo -= cur.spin * dt * (thinking ? 1.8 : 0.55) * spinMul;
      haloRings.setAttribute('transform', `rotate(${spinHalo.toFixed(2)})`);
    }

    if (bars.length) {
      const drive = Math.max(amplitude, mic * 0.7);
      for (let i = 0; i < bars.length; i++) {
        const phase = Math.sin(t * 6 + i * 0.9) * 0.5 + 0.5;
        bars[i].setAttribute('height',
          (18 + drive * (26 + phase * 62)).toFixed(1));
      }
    }

    const desat = frozen ? 0.35 : 1;
    let thinkMul = 1;
    if (thinking && !frozen) {
      thinkMul = 0.72 + 0.28 * (0.5 + 0.5 * Math.sin(t * 3.2));
    }
    core.setAttribute('transform', `scale(${(base * (1 + amplitude * 0.16)).toFixed(4)})`);
    core.setAttribute('opacity',
      Math.min(1, (cur.op + amplitude * 0.4) * thinkMul).toFixed(3));
    if (bloom > 0) {
      halo.setAttribute('transform',
        `scale(${(base * (1 + amplitude * 0.30 + mic * 0.12)).toFixed(4)})`);
      halo.setAttribute('opacity',
        Math.min(0.62, (cur.op * 0.22 + amplitude * 0.34 + mic * 0.26) * thinkMul).toFixed(3));
    }
    glow.style.opacity = Math.max(0, cur.op * 0.85 * desat * thinkMul).toFixed(3);
    glow.style.filter = frozen ? 'grayscale(1)' : (target.amber ? 'sepia(0.35) saturate(1.4)' : '');
    shift.setAttribute('opacity', (cur.op * desat * thinkMul).toFixed(3));
    if (frozen) {
      svg.style.filter = 'grayscale(1) brightness(0.85)';
    } else if (target.amber) {
      svg.style.filter = 'sepia(0.25) saturate(1.3) hue-rotate(-10deg)';
    } else {
      svg.style.filter = '';
    }

    outerRing.setAttribute('opacity', target.ring ? '0.85' : '0');

    meter.setAttribute('opacity', state === 'listening' ? 1 : 0);
    if (state === 'listening') {
      meter.setAttribute('stroke-dasharray',
        `${(mic * METER_CIRCUM).toFixed(1)} ${METER_CIRCUM}`);
    }

    const idleX = frozen ? 0 : Math.sin(t * 0.23) * 4 * cur.sway;
    const idleY = frozen ? 0 : Math.sin(t * 0.31) * 3 * cur.sway;
    shift.setAttribute('transform',
      `translate(${(256 + idleX).toFixed(2)},${(256 + idleY).toFixed(2)}) scale(${emblemScale})`);

    raf = requestAnimationFrame(frame);
  }
  raf = requestAnimationFrame(frame);

  return {
    get state() { return state; },
    setState(name, extra = {}) {
      if (!STATE_PARAMS[name] && name !== 'degraded' && name !== 'unreachable') {
        // allow known keys only
      }
      if (STATE_PARAMS[name]) state = name;
      if (extra.micLevel != null) micLevel = extra.micLevel;
      if (extra.amplitude != null) amplitude = extra.amplitude;
    },
    setThinking(v) { thinking = !!v; },
    setMicLevel(v) { micLevel = Math.min(1, Math.max(0, v || 0)); },
    setAmplitude(v) { amplitude = Math.min(1, Math.max(0, v || 0)); },
    destroy() {
      cancelAnimationFrame(raf);
      if (ro) ro.disconnect();
      container.innerHTML = '';
    },
  };
}
