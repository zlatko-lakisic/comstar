/**
 * COMSTAR product page — animated hero.
 *
 * Renders the emblem at hero scale and runs it through the real attention
 * ladder on a loop: ambient, noticed, engaged, listening, responding. The
 * caption names the current state, so twelve seconds of hero teaches the
 * whole interaction model without a diagram.
 *
 * Deliberately separate from terminal/kiosk/avatar.js. That renderer is
 * driven by live bridge messages; this one is a scripted demo. They share
 * presets.js and the same easing constants, so they cannot look different.
 *
 * Usage:
 *   <div id="hero-avatar"></div>
 *   <script type="module">
 *     import { mountHero } from './hero-avatar.js';
 *     mountHero(document.getElementById('hero-avatar'));
 *   </script>
 *
 * No box, no border, no card. See NOTES at the bottom.
 */

import { resolveEmblem } from './presets.js';

const SEQUENCE = [
  { state: 'ambient',    hold: 2.2, spin:  6, opacity: 0.30, scale: 0.86,
    caption: 'ambient · nobody in the room' },
  { state: 'noticed',    hold: 1.4, spin: 34, opacity: 0.62, scale: 0.94,
    caption: 'noticed · someone walked in' },
  { state: 'engaged',    hold: 1.8, spin:  0, opacity: 1.00, scale: 1.00,
    caption: 'engaged · that's you' },
  { state: 'listening',  hold: 2.6, spin: 12, opacity: 1.00, scale: 1.00,
    caption: 'listening · "what's on my calendar?"' },
  { state: 'responding', hold: 4.0, spin: 20, opacity: 1.00, scale: 1.00,
    caption: 'responding · speaking' },
  { state: 'engaged',    hold: 1.2, spin:  0, opacity: 1.00, scale: 1.00,
    caption: 'engaged · waiting for a follow-up' },
];

const DAMPING = 3.2;
const METER_CIRCUM = 2 * Math.PI * 232;
const SVG_NS = 'http://www.w3.org/2000/svg';

const CSS = `
.cs-hero { position: relative; display: flex; flex-direction: column;
           align-items: center; }
.cs-hero__glow {
  position: absolute; left: 50%; top: 50%;
  width: 140%; aspect-ratio: 1; transform: translate(-50%, -50%);
  background: radial-gradient(circle,
    rgba(61,220,255,0.10) 0%, rgba(61,220,255,0.03) 42%, transparent 68%);
  pointer-events: none; z-index: 0;
}
.cs-hero__svg {
  position: relative; z-index: 1; display: block;
  width: min(440px, 62vw); height: auto;
}
.cs-hero--thumb .cs-hero__glow { display: none; }
.cs-hero--thumb .cs-hero__svg { width: 120px; }
.cs-hero--thumb { cursor: pointer; }
.cs-hero--interactive { cursor: pointer; }
.cs-hero__status {
  position: relative; z-index: 1;
  display: flex; align-items: center; gap: 9px;
  margin-top: 16px; min-height: 20px;
}
.cs-hero__dot {
  width: 7px; height: 7px; border-radius: 50%;
  background: #3DDCFF; opacity: 0.28; transition: opacity 320ms ease;
}
.cs-hero__caption {
  font: 12px/1 ui-monospace, SFMono-Regular, Menlo, monospace;
  color: #6E7F90; letter-spacing: 0.04em;
}
@media (prefers-reduced-motion: reduce) {
  .cs-hero__status { opacity: 0; }
}
`;

let stylesInjected = false;
function injectStyles() {
  if (stylesInjected) return;
  const el = document.createElement('style');
  el.textContent = CSS;
  document.head.appendChild(el);
  stylesInjected = true;
}

/**
 * @param {HTMLElement} container
 * @param {object} [opts]
 * @param {string} [opts.emblem='starburst'] preset name or raw SVG markup
 * @param {number} [opts.bloom=9]            halo blur, SVG user units
 * @param {boolean} [opts.caption=true]      show the state caption
 * @param {boolean} [opts.animate=true]      false holds engaged (preset thumbs)
 * @param {'hero'|'thumb'} [opts.size='hero']
 * @returns {{destroy: () => void, jumpTo: (state: string) => void}}
 */
export function mountHero(container, opts = {}) {
  injectStyles();

  const emblem = resolveEmblem(opts.emblem);
  const bloom = opts.bloom ?? (opts.size === 'thumb' ? 0 : 9);
  const showCaption = opts.caption !== false;
  const animate = opts.animate !== false;
  const size = opts.size || 'hero';
  const uid = `csh${(mountHero._n = (mountHero._n || 0) + 1)}`;

  container.className = '';
  container.classList.add('cs-hero');
  if (size === 'thumb') container.classList.add('cs-hero--thumb');
  if (animate) container.classList.add('cs-hero--interactive');
  container.innerHTML = `
    <div class="cs-hero__glow"></div>
    <svg class="cs-hero__svg" viewBox="0 0 512 512" role="img"
         aria-label="The COMSTAR emblem cycling through its attention states:
                     dim while idle, brightening when someone enters, locking
                     on recognition, showing a level meter while listening,
                     then pulsing while it speaks.">
      <defs>
        <filter id="${uid}-bloom" x="-60%" y="-60%" width="220%" height="220%"
                color-interpolation-filters="sRGB">
          <feGaussianBlur stdDeviation="${bloom}"/>
        </filter>
      </defs>
      <g transform="translate(256,256)">
        <g class="cs-hero__halo">${emblem}</g>
        <g class="cs-hero__core">${emblem}</g>
        <circle class="cs-hero__meter" r="232" fill="none" stroke="#7fc4ff"
                stroke-width="6" stroke-linecap="round"
                stroke-dasharray="0 ${METER_CIRCUM}"
                transform="rotate(-90)" opacity="0"/>
      </g>
    </svg>
    ${showCaption ? `
    <div class="cs-hero__status">
      <span class="cs-hero__dot"></span>
      <span class="cs-hero__caption" aria-live="polite"></span>
    </div>` : ''}
  `;

  const core = container.querySelector('.cs-hero__core');
  const halo = container.querySelector('.cs-hero__halo');
  const meter = container.querySelector('.cs-hero__meter');
  const caption = container.querySelector('.cs-hero__caption');
  const dot = container.querySelector('.cs-hero__dot');

  if (bloom > 0) halo.setAttribute('filter', `url(#${uid}-bloom)`);

  // Optional hooks; a preset may have neither.
  const coreRings = core.querySelector('.cs-rings');
  const haloRings = halo.querySelector('.cs-rings');
  const bars = [...core.querySelectorAll('.cs-bars rect')];

  // Reduced motion or static thumbs: hold at engaged, no loop.
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (reduced || !animate) {
    core.setAttribute('opacity', '1');
    halo.setAttribute('opacity', bloom > 0 ? '0.22' : '0');
    core.setAttribute('transform', 'scale(1)');
    halo.setAttribute('transform', 'scale(1)');
    if (caption) caption.textContent = 'engaged';
    if (dot) dot.style.opacity = '1';
    return {
      destroy() { container.innerHTML = ''; container.className = ''; },
      jumpTo() {},
    };
  }

  let step = 0;
  let elapsed = 0;
  let last = performance.now();
  let spinCore = 0;
  let spinHalo = 0;
  let amplitude = 0;
  let raf = 0;
  let running = true;

  const cur = {
    spin: SEQUENCE[0].spin,
    opacity: SEQUENCE[0].opacity,
    scale: SEQUENCE[0].scale,
  };

  function announce() {
    const s = SEQUENCE[step];
    if (caption) caption.textContent = s.caption;
    if (dot) dot.style.opacity = s.state === 'ambient' ? '0.28' : '1';
  }
  announce();

  function jumpTo(stateName) {
    const idx = SEQUENCE.findIndex((s) => s.state === stateName);
    if (idx < 0) return;
    step = idx;
    elapsed = 0;
    announce();
  }

  container.addEventListener('click', () => jumpTo('listening'));
  container.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      jumpTo('listening');
    }
  });
  if (!container.hasAttribute('tabindex')) container.setAttribute('tabindex', '0');
  container.setAttribute('role', 'button');
  container.setAttribute('aria-label', 'COMSTAR emblem. Activate to jump to listening.');

  /**
   * Synthetic speech envelope. Syllable-rate modulation with a slower
   * phrase contour, tapering before the state ends so the pulse settles
   * rather than being cut off mid-word.
   */
  function envelope(t, hold) {
    if (t > hold - 0.5) return 0;
    const syllable = Math.max(0, Math.sin(t * 7.2)) ** 2;
    const phrase = 0.6 + 0.4 * Math.sin(t * 2.3);
    return syllable * phrase;
  }

  function frame(now) {
    if (!running) return;
    const dt = Math.min((now - last) / 1000, 0.1);
    last = now;
    elapsed += dt;

    const s = SEQUENCE[step];
    if (elapsed > s.hold) {
      elapsed = 0;
      step = (step + 1) % SEQUENCE.length;
      announce();
    }

    const target = SEQUENCE[step];
    const k = 1 - Math.exp(-DAMPING * dt);
    cur.spin    += (target.spin    - cur.spin)    * k;
    cur.opacity += (target.opacity - cur.opacity) * k;
    cur.scale   += (target.scale   - cur.scale)   * k;

    const env = target.state === 'responding'
      ? envelope(elapsed, target.hold) : 0;
    amplitude += (env - amplitude) * 0.30;

    const mic = target.state === 'listening'
      ? Math.abs(Math.sin(elapsed * 1.4)) * 0.42
        + Math.abs(Math.sin(elapsed * 3.6)) * 0.30
      : 0;

    spinCore += cur.spin * dt;
    spinHalo -= cur.spin * dt * 0.55;
    if (coreRings) coreRings.setAttribute('transform', `rotate(${spinCore})`);
    if (haloRings) haloRings.setAttribute('transform', `rotate(${spinHalo})`);

    if (bars.length) {
      const drive = Math.max(amplitude, mic * 0.7);
      for (let i = 0; i < bars.length; i++) {
        const phase = Math.sin(elapsed * 6 + i * 0.9) * 0.5 + 0.5;
        bars[i].setAttribute('height', (18 + drive * (26 + phase * 62)).toFixed(1));
      }
    }

    // Ambient breathes; every other state holds nearly still.
    const breathe = 1 + Math.sin(elapsed * 0.4) * 0.03
      * (target.state === 'ambient' ? 1 : 0.15);
    const base = cur.scale * breathe;

    core.setAttribute('transform', `scale(${(base * (1 + amplitude * 0.17)).toFixed(4)})`);
    halo.setAttribute('transform', `scale(${(base * (1 + amplitude * 0.34 + mic * 0.12)).toFixed(4)})`);
    core.setAttribute('opacity', Math.min(1, cur.opacity + amplitude * 0.35));
    halo.setAttribute('opacity', Math.min(0.66, cur.opacity * 0.22 + amplitude * 0.42 + mic * 0.28));

    meter.setAttribute('opacity', target.state === 'listening' ? 1 : 0);
    meter.setAttribute('stroke-dasharray', `${(mic * METER_CIRCUM).toFixed(1)} ${METER_CIRCUM}`);

    raf = requestAnimationFrame(frame);
  }

  raf = requestAnimationFrame(frame);

  // Stop the loop when the hero scrolls out of view. A hero that keeps
  // running at 60fps while the reader is at the FAQ is pure battery drain.
  const io = new IntersectionObserver(([entry]) => {
    if (entry.isIntersecting && !running) {
      running = true;
      last = performance.now();
      raf = requestAnimationFrame(frame);
    } else if (!entry.isIntersecting && running) {
      running = false;
      cancelAnimationFrame(raf);
    }
  }, { threshold: 0.05 });
  io.observe(container);

  return {
    destroy() {
      running = false;
      cancelAnimationFrame(raf);
      io.disconnect();
      container.innerHTML = '';
      container.className = '';
    },
    jumpTo,
  };
}

/* -----------------------------------------------------------------------
NOTES FOR THE PAGE

1. Remove the card. The current hero wraps the emblem in a rounded panel
   with a visible border, which reads as a logo thumbnail. Delete the
   background, the border and the border-radius on that container. The
   glow div in this component replaces it: soft, edgeless, no boundary
   for the eye to catch on.

2. Make it bigger. `min(440px, 62vw)` against a ~1650px viewport is
   roughly double the current size. It should be the first thing seen,
   ahead of the headline, not a badge above it.

3. Fix the subhead. "Runs entirely on hardware you already own" is
   contradicted by the build section and the FAQ. Use:
   "Runs on your own hardware, on a home server with a GPU."

4. The caption is the point. Twelve seconds of this teaches the whole
   attention ladder, which currently costs a section and a diagram.
   Keep it small and dim so it informs without competing.

5. Consider a click affordance. Clicking the emblem could jump the
   sequence straight to `listening`. Cheap, and it rewards the one
   interaction every visitor will try.
----------------------------------------------------------------------- */
