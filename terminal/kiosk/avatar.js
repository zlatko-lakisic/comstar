/**
 * COMSTAR avatar renderer (2D).
 *
 * Renders the ComStar starburst as live inline SVG. No WebGL, no GLB, no blend
 * shapes. The expressive channels are:
 *
 *   - ring rotation and brightness, driven by attention state
 *   - halo swell, driven by mic level while listening
 *   - core pulse, driven by speech amplitude read from an AnalyserNode on the
 *     audio element we are already playing (so it cannot drift out of sync)
 *   - a small parallax offset, driven by the face bounding box CodeProject.AI
 *     already returns
 *
 * The emblem renders alone on a dark field. There is no background image and
 * no 3D model: the mark is the avatar.
 *
 * Public API is identical to the WebGL renderer, so the two are swappable
 * without touching index.html or bridge_client.js.
 */

import { resolveEmblem } from './presets.js';
import { STATE_PARAMS } from './emblem.js';

export { STATE_PARAMS };

// Opacity ease is slower than spin/scale so sleep <-> listen reads as a fade,
// but still fast enough that "go to sleep" dims within ~0.5s.
const STATE_DAMPING = 3.5;
const OPACITY_DAMPING = 3.2;
const GAZE_DAMPING = 2.5;
const MAX_DRIFT = 18;      // user units the emblem leans toward a person
const METER_CIRCUM = 2 * Math.PI * 226;

function _clampNum(raw, fallback, min, max) {
  const n = Number(raw);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(max, n));
}

export class ComstarAvatar {
  /**
   * @param {HTMLElement} container  element to mount into; sized by CSS
   * @param {object} opts
   * @param {(type:string,data:object)=>void} opts.onEvent
   * @param {string} [opts.emblem='starburst']  preset name, or raw SVG markup
   * @param {number}  [opts.emblemScale=0.62] emblem size inside the fitted square
   *                   (SVG user-space scale; keeps star points off the edges)
   * @param {number}  [opts.fitMaxPx=720] max CSS square edge in px — keeps the
   *                   mark roughly the same size across resolutions; leftover
   *                   stage becomes margin. Shrinks when the stage is smaller.
   * @param {number}  [opts.fitFill=0.92] fraction of the stage short axis to use
   *                   before applying fitMaxPx (always leave a little gutter)
   * @param {number}  [opts.bloom=0] halo blur in SVG user units (0 disables).
   *                   User units, not CSS px, so it is invariant to panel size.
   * @param {number}  [opts.maxFps=24] hard cap for the animation loop (Pi GPU).
   */
  constructor(container, opts = {}) {
    this.container = container;
    this.onEvent = opts.onEvent || (() => {});
    this.emblemScale = opts.emblemScale ?? 0.62;
    this.fitMaxPx = _clampNum(opts.fitMaxPx ?? opts.maxSize, 720, 200, 4096);
    this.fitFill = _clampNum(opts.fitFill, 0.92, 0.5, 1);
    this.bloom = opts.bloom ?? 0;
    this.maxFps = Math.max(8, Math.min(60, opts.maxFps ?? 12));
    this.emblemName = typeof opts.emblem === 'string' ? opts.emblem : 'starburst';
    this.emblem = resolveEmblem(opts.emblem);

    this.state = 'ambient';
    this.thinking = false;
    this.amplitude = 0;
    this.micLevel = 0;
    this.gaze = { x: 0, y: 0 };
    this.gazeTarget = { x: 0, y: 0 };
    this.cur = { ...STATE_PARAMS.ambient };

    this._spinCore = 0;
    this._spinHalo = 0;
    this._t = 0;
    this._last = performance.now();
    this._fps = this.maxFps;
    this._frameBound = this._frame.bind(this);
    this._raf = 0;
    this._visible = typeof document === 'undefined'
      ? true
      : document.visibilityState !== 'hidden';

    this._build();
    this._initAudio();
    if (typeof document !== 'undefined') {
      document.addEventListener('visibilitychange', () => {
        this._visible = document.visibilityState !== 'hidden';
        if (this._visible && !this._raf) {
          this._last = performance.now();
          this._raf = requestAnimationFrame(this._frameBound);
        }
      });
    }
    this._raf = requestAnimationFrame(this._frameBound);
  }

  // ------------------------------------------------------------------ DOM

  /** Mount emblem geometry with createElementNS only — no DOMParser/innerHTML.
   *  Pi Chromium deadlocks parsing the preset SVG markup strings during ctor. */
  _mountEmblem(parent) {
    const ns = 'http://www.w3.org/2000/svg';
    const el = (tag, attrs = {}) => {
      const node = document.createElementNS(ns, tag);
      for (const [k, v] of Object.entries(attrs)) {
        if (v != null) node.setAttribute(k, String(v));
      }
      return node;
    };
    const pale = '#eaf6ff';
    const blue = '#a8d8ff';
    const cyan = '#7fc4ff';
    const dark = '#0d2136';

    const rings = el('g', { class: 'cs-rings' });
    rings.appendChild(el('circle', {
      r: '196', fill: 'none', stroke: '#cfeaff', 'stroke-width': '7',
      'stroke-dasharray': '330 105',
    }));
    for (const [r, dash] of [['172', '72 370'], ['155', '72 335'], ['138', '72 300']]) {
      rings.appendChild(el('circle', {
        r, fill: 'none', stroke: blue, 'stroke-width': '5', 'stroke-dasharray': dash,
      }));
    }
    parent.appendChild(rings);

    const star = el('g', { class: 'cs-star' });
    star.appendChild(el('path', {
      fill: pale,
      d: 'M0 -246 L19 -60 L77 -123 L35 -28 L169 -53 L46 0 L169 53 L35 28 L77 123 L19 60 L0 246 L-19 60 L-77 123 L-35 28 L-169 53 L-46 0 L-169 -53 L-35 -28 L-77 -123 L-19 -60 Z',
    }));
    star.appendChild(el('path', {
      fill: dark,
      d: 'M0 -109 L16 -35 L67 -60 L25 -14 L95 0 L25 14 L67 60 L16 35 L0 109 L-16 35 L-67 60 L-25 14 L-95 0 L-25 -14 L-67 -60 L-16 -35 Z',
    }));
    star.appendChild(el('path', {
      fill: 'none', stroke: cyan, 'stroke-width': '4',
      d: 'M0 -46 L39 35 L-39 35 Z',
    }));
    const marks = el('g', { stroke: cyan, 'stroke-width': '2.5' });
    marks.appendChild(el('path', {
      d: 'M-18 22 L-18 4 M0 22 L0 -2 M18 22 L18 8 M-18 14 L0 8 M0 8 L18 14',
    }));
    for (const [cx, cy] of [[-18, 2], [0, -4], [18, 6]]) {
      marks.appendChild(el('circle', { cx, cy, r: '3', fill: cyan, stroke: 'none' }));
    }
    star.appendChild(marks);
    parent.appendChild(star);
  }

  _build() {
    this.container.innerHTML = '';
    // Match the GitHub Pages hero: deep navy with a soft cyan wash that
    // falls off from the emblem center. CSS only — no SVG blur on VideoCore.
    Object.assign(this.container.style, {
      position: 'relative',
      overflow: 'hidden',
      background:
        'radial-gradient(ellipse 80% 55% at 50% 48%, rgba(61,220,255,0.08), transparent 72%), #060d16',
    });

    const uid = `cs${(ComstarAvatar._n = (ComstarAvatar._n || 0) + 1)}`;
    const ns = 'http://www.w3.org/2000/svg';

    // Soft edgeless glow behind the mark (same recipe as site/public/avatar).
    const glow = document.createElement('div');
    glow.className = 'cs-glow';
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
    this.container.appendChild(glow);
    this.glow = glow;

    const svg = document.createElementNS(ns, 'svg');
    svg.setAttribute('viewBox', '0 0 512 512');
    svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
    svg.setAttribute('width', '512');
    svg.setAttribute('height', '512');
    svg.setAttribute('role', 'img');
    // Size as an explicit CSS square. Chromium/Ozone on the portrait panel
    // stretches width:100%;height:100% SVGs and ignores preserveAspectRatio,
    // which turns rings into tall ellipses on 768×1024.
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
    const title = document.createElementNS(ns, 'title');
    title.textContent = 'COMSTAR';
    svg.appendChild(title);

    const defs = document.createElementNS(ns, 'defs');
    const useBloom = this.bloom > 0;
    if (useBloom) {
      const filter = document.createElementNS(ns, 'filter');
      filter.setAttribute('id', `${uid}-bloom`);
      filter.setAttribute('x', '-60%');
      filter.setAttribute('y', '-60%');
      filter.setAttribute('width', '220%');
      filter.setAttribute('height', '220%');
      filter.setAttribute('color-interpolation-filters', 'sRGB');
      const blur = document.createElementNS(ns, 'feGaussianBlur');
      blur.setAttribute('stdDeviation', String(this.bloom));
      filter.appendChild(blur);
      defs.appendChild(filter);
      svg.appendChild(defs);
    }

    const shift = document.createElementNS(ns, 'g');
    shift.setAttribute('class', 'cs-shift');
    shift.setAttribute('transform', 'translate(256,256)');

    const halo = document.createElementNS(ns, 'g');
    halo.setAttribute('class', 'cs-halo');
    if (useBloom) this._mountEmblem(halo);

    const core = document.createElementNS(ns, 'g');
    core.setAttribute('class', 'cs-core');
    this._mountEmblem(core);

    const meter = document.createElementNS(ns, 'circle');
    meter.setAttribute('class', 'cs-meter');
    meter.setAttribute('r', '226');
    meter.setAttribute('fill', 'none');
    meter.setAttribute('stroke', '#7fc4ff');
    meter.setAttribute('stroke-width', '6');
    meter.setAttribute('stroke-linecap', 'round');
    meter.setAttribute('stroke-dasharray', `0 ${METER_CIRCUM}`);
    meter.setAttribute('transform', 'rotate(-90)');
    meter.setAttribute('opacity', '0');

    shift.appendChild(halo);
    shift.appendChild(core);
    shift.appendChild(meter);
    svg.appendChild(shift);
    this.container.appendChild(svg);
    this.svg = svg;
    this._fitSquare();
    // Defer ResizeObserver — observing in the same turn as the first layout
    // has deadlocked Pi Chromium (ctor never returns → blank emblem).
    if (typeof window !== 'undefined') {
      window.setTimeout(() => {
        if (this._ro || !this.container) return;
        if (typeof ResizeObserver !== 'undefined') {
          this._ro = new ResizeObserver(() => this._fitSquare());
          this._ro.observe(this.container);
        } else {
          this._onResize = () => this._fitSquare();
          window.addEventListener('resize', this._onResize);
        }
        this._fitSquare();
      }, 0);
    }

    this.shift = shift;
    this.halo = halo;
    this.core = core;
    this.meter = meter;

    // Halo is a blurred twin of the core. feGaussianBlur is the expensive
    // part on VideoCore — keep stdDeviation low, or bloom=0 to skip entirely.
    if (this.bloom > 0) {
      this.halo.setAttribute('filter', `url(#${uid}-bloom)`);
    } else {
      // No bloom → drop the second emblem so we do not double SVG work.
      this.halo.style.display = 'none';
    }

    // Both hooks are optional; a preset may use neither.
    this.haloRings = this.halo.querySelector('.cs-rings');
    this.coreRings = this.core.querySelector('.cs-rings');
    this.bars = this.bloom > 0
      ? [
          ...this.core.querySelectorAll('.cs-bars rect'),
          ...this.halo.querySelectorAll('.cs-bars rect'),
        ]
      : [...this.core.querySelectorAll('.cs-bars rect')];
  }

  /** Keep the SVG (and its glow) a centered square; cap size across resolutions. */
  _fitSquare() {
    if (!this.svg || !this.container) return;
    const w = this.container.clientWidth || 0;
    const h = this.container.clientHeight || 0;
    // Fall back to viewport when the stage has not laid out yet (0×0).
    const vw = (typeof window !== 'undefined' && window.innerWidth) || 600;
    const vh = (typeof window !== 'undefined' && window.innerHeight) || 1024;
    const aw = w >= 1 ? w : vw;
    const ah = h >= 1 ? h : Math.max(1, vh - 92);
    const short = Math.min(aw, ah);
    // Same visual size on large panels: use short axis (with a small gutter),
    // but never grow past fitMaxPx — extra space becomes margin around center.
    const s = Math.max(
      1,
      Math.round(Math.min(short * this.fitFill, this.fitMaxPx)),
    );
    if (s < 1) return;
    // Avoid ResizeObserver feedback loops on Pi Chromium.
    if (this._fitPx === s) return;
    this._fitPx = s;
    this.svg.style.width = `${s}px`;
    this.svg.style.height = `${s}px`;
    if (this.glow) {
      const g = Math.round(s * 1.4);
      this.glow.style.width = `${g}px`;
      this.glow.style.height = `${g}px`;
    }
  }

  // ---------------------------------------------------------------- audio

  _initAudio() {
    this.audio = new Audio();
    this.audio.crossOrigin = 'anonymous';
    this.audio.preload = 'auto';
    this._wired = false;
    this._speaking = false;
    this._started = false;

    this.audio.addEventListener('playing', () => {
      if (!this._started) { this._started = true; this.onEvent('speak.started', {}); }
    });
    this.audio.addEventListener('ended', () => this._endSpeak());
    this.audio.addEventListener('error', () => {
      this.onEvent('error', { code: 'audio_failed', message: 'Playback failed' });
      this._endSpeak();
    });
  }

  /** Built lazily: AudioContext construction is refused before a user gesture
   *  on some platforms, and a kiosk never receives one. */
  _ensureAnalyser() {
    if (this._wired) return;
    this._wired = true;
    try {
      this.ctx = new (window.AudioContext || window.webkitAudioContext)();
      this._mediaSrc = this.ctx.createMediaElementSource(this.audio);
      this.analyser = this.ctx.createAnalyser();
      this.analyser.fftSize = 256;
      this.analyser.smoothingTimeConstant = 0.75;
      this._bins = new Uint8Array(this.analyser.frequencyBinCount);
      this._mediaSrc.connect(this.analyser);
      this._outputMuted = false;
    } catch {
      this.analyser = null;   // speech still plays, only the pulse is lost
      this._mediaSrc = null;
    }
  }

  /** When true, keep analyser (emblem pulse) but do not feed speakers — paplay owns HDMI. */
  _setOutputMuted(mute) {
    this._outputMuted = !!mute;
    this.audio.muted = !!mute;
    if (!this.analyser || !this.ctx) return;
    try {
      this.analyser.disconnect();
    } catch { /* not connected */ }
    if (!mute) {
      this.analyser.connect(this.ctx.destination);
    }
  }

  _readAmplitude() {
    if (!this.analyser) return 0;
    this.analyser.getByteTimeDomainData(this._bins);
    let sum = 0;
    for (let i = 0; i < this._bins.length; i++) {
      const v = (this._bins[i] - 128) / 128;
      sum += v * v;
    }
    // RMS, lifted so quiet speech still reads visually across a room.
    return Math.min(1, Math.sqrt(sum / this._bins.length) * 3.2);
  }

  _endSpeak() {
    if (!this._speaking) return;
    this._speaking = false;
    this._started = false;
    this.amplitude = 0;
    this.onEvent('speak.ended', {});
  }

  // ----------------------------------------------------------- public API

  setState(state) {
    if (!STATE_PARAMS[state]) return;
    this.state = state;
    // Sleep ↔ listen/engaged both ease via STATE_DAMPING / OPACITY_DAMPING in
    // _frame — do not snap enter-sleep or wake-from-sleep looks one-sided.
  }

  setThinking(active) { this.thinking = !!active; }

  setMicLevel(level) { this.micLevel = Math.min(1, Math.max(0, level || 0)); }

  /** @param {number} x -1 (left) to 1 (right) @param {number} y -1 to 1 */
  setGaze(x, y = 0) {
    this.gazeTarget.x = Math.min(1, Math.max(-1, x));
    this.gazeTarget.y = Math.min(1, Math.max(-1, y));
  }

  /** Convert a CodeProject.AI bounding box into a gaze target. */
  setGazeFromBox(box, frameWidth, frameHeight) {
    const cx = (box.x_min + box.x_max) / 2;
    const cy = (box.y_min + box.y_max) / 2;
    this.setGaze((cx / frameWidth) * 2 - 1, -((cy / frameHeight) * 2 - 1));
  }

  /**
   * Live tuning without remounting the page.
   * @param {{bloom?: number, maxFps?: number, fps?: number, emblemScale?: number, scale?: number, emblem?: string, fitMaxPx?: number, maxSize?: number, fitFill?: number}} opts
   * @returns {{bloom: number, maxFps: number, emblemScale: number, emblem: string, fitMaxPx: number, fitFill: number}}
   */
  setOptions(opts = {}) {
    if (opts.bloom != null && Number.isFinite(Number(opts.bloom))) {
      this._applyBloom(Number(opts.bloom));
    }
    const fpsRaw = opts.maxFps ?? opts.fps;
    if (fpsRaw != null && Number.isFinite(Number(fpsRaw))) {
      this.maxFps = Math.max(8, Math.min(60, Number(fpsRaw)));
    }
    const scaleRaw = opts.emblemScale ?? opts.scale;
    if (scaleRaw != null && Number.isFinite(Number(scaleRaw))) {
      this.emblemScale = Math.max(0.2, Math.min(1.2, Number(scaleRaw)));
    }
    const maxRaw = opts.fitMaxPx ?? opts.maxSize;
    if (maxRaw != null && Number.isFinite(Number(maxRaw))) {
      this.fitMaxPx = _clampNum(maxRaw, this.fitMaxPx, 200, 4096);
      this._fitPx = undefined;
      this._fitSquare();
    }
    if (opts.fitFill != null && Number.isFinite(Number(opts.fitFill))) {
      this.fitFill = _clampNum(opts.fitFill, this.fitFill, 0.5, 1);
      this._fitPx = undefined;
      this._fitSquare();
    }
    if (opts.emblem != null && String(opts.emblem).trim()) {
      const name = String(opts.emblem).trim();
      const next = resolveEmblem(name);
      if (next) {
        this.emblemName = name;
        this.emblem = next;
        const state = this.state;
        const thinking = this.thinking;
        this._build();
        this.setState(state);
        this.setThinking(thinking);
      }
    }
    return this.getOptions();
  }

  /** @returns {{bloom: number, maxFps: number, emblemScale: number, emblem: string, fitMaxPx: number, fitFill: number}} */
  getOptions() {
    return {
      bloom: this.bloom,
      maxFps: this.maxFps,
      emblemScale: this.emblemScale,
      emblem: this.emblemName || 'starburst',
      fitMaxPx: this.fitMaxPx,
      fitFill: this.fitFill,
    };
  }

  _applyBloom(value) {
    const bloom = Math.max(0, Math.min(24, value));
    this.bloom = bloom;
    if (!this.svg || !this.halo) return;
    const filter = this.svg.querySelector('filter feGaussianBlur');
    if (filter) filter.setAttribute('stdDeviation', String(bloom));
    const filterEl = this.svg.querySelector('filter');
    const filterId = filterEl?.id;
    if (bloom > 0 && filterId) {
      this.halo.style.display = '';
      this.halo.setAttribute('filter', `url(#${filterId})`);
      this.bars = [
        ...this.core.querySelectorAll('.cs-bars rect'),
        ...this.halo.querySelectorAll('.cs-bars rect'),
      ];
    } else {
      this.halo.removeAttribute('filter');
      this.halo.style.display = 'none';
      this.bars = [...this.core.querySelectorAll('.cs-bars rect')];
    }
  }

  /**
   * @param {string} audioUrl
   * @param {{ muteOutput?: boolean }} [opts]
   */
  speak(audioUrl, opts = {}) {
    this._ensureAnalyser();
    this._setOutputMuted(!!opts.muteOutput);
    if (this.ctx && this.ctx.state === 'suspended') this.ctx.resume();
    this._speaking = true;
    this._started = false;
    this.audio.src = audioUrl;
    this.audio.play().catch(() => {
      this.onEvent('error', { code: 'autoplay_blocked', message: 'Playback rejected' });
      this._endSpeak();
    });
  }

  cancelSpeak() {
    if (!this._speaking) return;
    this.audio.pause();
    this.audio.currentTime = 0;
    this._endSpeak();
  }

  stats() {
    return {
      webglVendor: 'svg',
      fps: Math.round(this._fps),
    };
  }

  dispose() {
    cancelAnimationFrame(this._raf);
    this._raf = 0;
    this.container.innerHTML = '';
  }

  // ----------------------------------------------------------------- loop

  _targetFps() {
    // Keep full rate while easing into/out of sleep so the fade matches wake.
    const target = STATE_PARAMS[this.state] || STATE_PARAMS.ambient;
    const easing =
      Math.abs(this.cur.op - target.op) > 0.02 ||
      Math.abs(this.cur.sc - target.sc) > 0.01;
    if (easing) return this.maxFps;

    // Idle ambient / sleep is mostly decorative — run cooler on the Pi.
    if ((this.state === 'ambient' || this.state === 'sleeping') && !this.thinking) {
      return Math.min(12, this.maxFps);
    }
    if (this.state === 'engaged' && !this.thinking) return Math.min(18, this.maxFps);
    return this.maxFps;
  }

  _frame(now) {
    this._raf = 0;
    if (!this._visible) return;

    const minDt = 1 / this._targetFps();
    const elapsed = (now - this._last) / 1000;
    if (elapsed < minDt * 0.92) {
      this._raf = requestAnimationFrame(this._frameBound);
      return;
    }

    const dt = Math.min(elapsed, 0.1);
    this._last = now;
    this._t += dt;
    this._fps = this._fps * 0.85 + (1 / Math.max(dt, 1e-3)) * 0.15;

    const target = STATE_PARAMS[this.state] || STATE_PARAMS.ambient;
    const k = 1 - Math.exp(-STATE_DAMPING * dt);
    const kOp = 1 - Math.exp(-OPACITY_DAMPING * dt);
    for (const key of Object.keys(target)) {
      const damp = key === 'op' ? kOp : k;
      this.cur[key] += (target[key] - this.cur[key]) * damp;
    }

    if (this.state === 'responding' && this._speaking) {
      this.amplitude += (this._readAmplitude() - this.amplitude) * 0.35;
    } else if (this.state !== 'responding') {
      this.amplitude *= 0.9;
    }

    const breathe = 1 + Math.sin(this._t * 0.4) * 0.03 * this.cur.sway;
    const base = this.cur.sc * breathe;
    const mic = this.state === 'listening' ? this.micLevel : 0;
    const useHalo = this.bloom > 0;

    // Thinking counter-rotates the halo rings against the core rings.
    this._spinCore += this.cur.spin * dt;
    if (this.coreRings) {
      this.coreRings.setAttribute('transform', `rotate(${this._spinCore.toFixed(2)})`);
    }
    if (useHalo && this.haloRings) {
      this._spinHalo -= this.cur.spin * dt * (this.thinking ? 1.8 : 0.55);
      this.haloRings.setAttribute('transform', `rotate(${this._spinHalo.toFixed(2)})`);
    }

    // Spectrum presets: each bar reacts with its own phase so the ring reads
    // as a waveform rather than a single ring breathing in and out.
    if (this.bars.length) {
      const drive = Math.max(this.amplitude, mic * 0.7);
      for (let i = 0; i < this.bars.length; i++) {
        const phase = Math.sin(this._t * 6 + i * 0.9) * 0.5 + 0.5;
        this.bars[i].setAttribute('height',
          (18 + drive * (26 + phase * 62)).toFixed(1));
      }
    }

    const coreScale = base * (1 + this.amplitude * 0.16);
    this.core.setAttribute('transform', `scale(${coreScale.toFixed(4)})`);
    // Thinking opacity ping: slightly opaque ↔ full.
    let opMul = 1;
    if (this.thinking) {
      opMul = 0.72 + 0.28 * (0.5 + 0.5 * Math.sin(this._t * 3.2));
    }
    const coreOp = Math.min(1, (this.cur.op + this.amplitude * 0.4) * opMul);
    this.core.setAttribute('opacity', coreOp.toFixed(3));
    if (useHalo) {
      const haloScale = base * (1 + this.amplitude * 0.30 + mic * 0.12);
      this.halo.setAttribute('transform', `scale(${haloScale.toFixed(4)})`);
      this.halo.setAttribute('opacity',
        Math.min(0.62, (this.cur.op * 0.22 + this.amplitude * 0.34 + mic * 0.26) * opMul).toFixed(3));
    }
    // Stage glow tracks the same fade — no floor, or sleep never looks dim.
    if (this.glow) {
      this.glow.style.opacity = Math.max(0, this.cur.op * 0.85 * opMul).toFixed(3);
    }
    // Whole emblem group dims (stroke stays visible at low op on IPS panels).
    this.shift.setAttribute('opacity', (this.cur.op * opMul).toFixed(3));

    this.meter.setAttribute('opacity', this.state === 'listening' ? 1 : 0);
    if (this.state === 'listening') {
      this.meter.setAttribute('stroke-dasharray',
        `${(mic * METER_CIRCUM).toFixed(1)} ${METER_CIRCUM}`);
    }

    // Gaze, damped so the emblem eases rather than snapping.
    const g = 1 - Math.exp(-GAZE_DAMPING * dt);
    this.gaze.x += (this.gazeTarget.x - this.gaze.x) * g;
    this.gaze.y += (this.gazeTarget.y - this.gaze.y) * g;

    const idleX = Math.sin(this._t * 0.23) * 4 * this.cur.sway;
    const idleY = Math.sin(this._t * 0.31) * 3 * this.cur.sway;
    const dx = this.gaze.x * MAX_DRIFT + idleX;
    const dy = -this.gaze.y * MAX_DRIFT * 0.5 + idleY;
    this.shift.setAttribute('transform',
      `translate(${(256 + dx).toFixed(2)},${(256 + dy).toFixed(2)}) scale(${this.emblemScale})`);

    this._raf = requestAnimationFrame(this._frameBound);
  }
}
