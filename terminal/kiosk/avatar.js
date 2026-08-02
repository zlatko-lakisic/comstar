import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';

/**
 * COMSTAR avatar renderer.
 *
 * Renders a static mech-head GLB with the ComStar starburst as an additively
 * blended child plane. The head has no rig and no blend shapes by design: the
 * expressive channels are (a) the starburst, driven by attention state and
 * speech amplitude, and (b) head yaw, driven by the face bounding box that
 * CodeProject.AI already returns.
 *
 * The GLB is optional. If it fails to load, or WebGL never comes up, the
 * starburst renders alone on a dark field and everything else keeps working.
 * See IMPLEMENTATION_PLAN M7.5: the avatar must never be able to take down the
 * voice assistant.
 */

const STATE_PARAMS = {
  ambient:    { ringSpin: 0.06, opacity: 0.30, scale: 0.86, keyLight: 0.25, sway: 1.0 },
  noticed:    { ringSpin: 0.50, opacity: 0.62, scale: 0.94, keyLight: 0.60, sway: 0.4 },
  engaged:    { ringSpin: 0.00, opacity: 1.00, scale: 1.00, keyLight: 1.00, sway: 0.15 },
  listening:  { ringSpin: 0.12, opacity: 1.00, scale: 1.00, keyLight: 1.00, sway: 0.15 },
  responding: { ringSpin: 0.20, opacity: 1.00, scale: 1.00, keyLight: 1.00, sway: 0.15 },
};

const HEAD_GLB = './assets/comstar-head.glb';
const STARBURST_SVG = './assets/starburst.svg';

const MAX_YAW = THREE.MathUtils.degToRad(25);
const MAX_PITCH = THREE.MathUtils.degToRad(10);
const GAZE_DAMPING = 2.5;
const STATE_DAMPING = 3.5;

export class ComstarAvatar {
  constructor(canvas, opts = {}) {
    this.canvas = canvas;
    this.onEvent = opts.onEvent || (() => {});
    this.state = 'ambient';
    this.headLoaded = false;

    this.gaze = { x: 0, y: 0 };
    this.gazeTarget = { x: 0, y: 0 };

    this.amplitude = 0;
    this.micLevel = 0;
    this.thinking = false;
    this.clock = new THREE.Clock();
    this.t = 0;

    this.cur = { ...STATE_PARAMS.ambient };

    this._initScene();
    this._initStarburst();
    this._loadHead();
    this._initAudio();

    this._onResize = this._resize.bind(this);
    window.addEventListener('resize', this._onResize);
    this._resize();
    this.renderer.setAnimationLoop(this._frame.bind(this));
  }

  // ---------------------------------------------------------------- scene

  _initScene() {
    this.renderer = new THREE.WebGLRenderer({
      canvas: this.canvas,
      antialias: true,
      powerPreference: 'high-performance',
    });
    // Pi 4 has no headroom for supersampling. Cap hard.
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 1.5));
    this.renderer.outputColorSpace = THREE.SRGBColorSpace;
    this.renderer.shadowMap.enabled = false;

    this.scene = new THREE.Scene();
    this.scene.background = new THREE.Color(0x060d16);

    this.camera = new THREE.PerspectiveCamera(28, 1, 0.1, 100);
    this.camera.position.set(0, 0, 4.2);

    this.headGroup = new THREE.Group();
    this.scene.add(this.headGroup);

    this.ambientLight = new THREE.HemisphereLight(0x9fd0ff, 0x101820, 0.55);
    this.scene.add(this.ambientLight);

    this.keyLight = new THREE.DirectionalLight(0xdceeff, 1.6);
    this.keyLight.position.set(1.4, 1.8, 2.4);
    this.scene.add(this.keyLight);

    this.rimLight = new THREE.DirectionalLight(0x5aa9e6, 1.0);
    this.rimLight.position.set(-2.2, 0.6, -1.6);
    this.scene.add(this.rimLight);

    this.canvas.addEventListener('webglcontextlost', (e) => {
      e.preventDefault();
      this.onEvent('error', { code: 'webgl_context_lost', message: 'WebGL context lost' });
      setTimeout(() => window.location.reload(), 1500);
    });
  }

  // ------------------------------------------------------------ starburst

  _initStarburst() {
    const tex = new THREE.TextureLoader().load(STARBURST_SVG);
    tex.colorSpace = THREE.SRGBColorSpace;

    this.starburst = new THREE.Group();

    // Fake bloom: a larger, dimmer copy behind the sharp one. Two additive
    // quads cost effectively nothing; a real post-process bloom pass does not
    // survive VideoCore VI at 24fps.
    const halo = new THREE.Mesh(
      new THREE.PlaneGeometry(3.4, 3.4),
      new THREE.MeshBasicMaterial({
        map: tex, transparent: true, blending: THREE.AdditiveBlending,
        depthWrite: false, opacity: 0.28,
      })
    );
    const core = new THREE.Mesh(
      new THREE.PlaneGeometry(2.6, 2.6),
      new THREE.MeshBasicMaterial({
        map: tex, transparent: true, blending: THREE.AdditiveBlending,
        depthWrite: false, opacity: 1.0,
      })
    );
    this.halo = halo;
    this.core = core;
    this.starburst.add(halo, core);

    // Sits in front of the faceplate, parented to the head so it turns with it.
    this.starburst.position.set(0, 0.05, 0.85);
    this.headGroup.add(this.starburst);
  }

  // ----------------------------------------------------------------- head

  _loadHead() {
    new GLTFLoader().load(
      HEAD_GLB,
      (gltf) => {
        const head = gltf.scene;
        this._frameObject(head, 2.2);
        this.headGroup.add(head);
        this.head = head;
        this.headLoaded = true;
        this.onEvent('head.loaded', {});
      },
      undefined,
      () => {
        // Starburst-only mode. Deliberately not fatal.
        this.headLoaded = false;
        this.onEvent('error', {
          code: 'glb_load_failed',
          message: 'Head GLB missing; running starburst-only',
        });
      }
    );
  }

  /** Scale and centre an arbitrary GLB so its height fills `targetHeight`. */
  _frameObject(obj, targetHeight) {
    const box = new THREE.Box3().setFromObject(obj);
    const size = box.getSize(new THREE.Vector3());
    const center = box.getCenter(new THREE.Vector3());
    const scale = targetHeight / (size.y || 1);
    obj.scale.setScalar(scale);
    obj.position.sub(center.multiplyScalar(scale));
  }

  // ---------------------------------------------------------------- audio

  _initAudio() {
    this.audio = new Audio();
    this.audio.crossOrigin = 'anonymous';
    this.audio.preload = 'auto';
    this._audioWired = false;
    this._speakStarted = false;

    this.audio.addEventListener('playing', () => {
      if (!this._speakStarted) {
        this._speakStarted = true;
        this.onEvent('speak.started', {});
      }
    });
    this.audio.addEventListener('ended', () => this._endSpeak());
    this.audio.addEventListener('error', () => {
      this.onEvent('error', { code: 'audio_failed', message: 'Playback failed' });
      this._endSpeak();
    });
  }

  /** Lazily built: AudioContext cannot be created before a user gesture on
   *  some platforms, and the kiosk has no gestures. Built on first speak. */
  _ensureAnalyser() {
    if (this._audioWired) return;
    try {
      this.audioCtx = new (window.AudioContext || window.webkitAudioContext)();
      const src = this.audioCtx.createMediaElementSource(this.audio);
      this.analyser = this.audioCtx.createAnalyser();
      this.analyser.fftSize = 256;
      this.analyser.smoothingTimeConstant = 0.75;
      this._bins = new Uint8Array(this.analyser.frequencyBinCount);
      src.connect(this.analyser);
      this.analyser.connect(this.audioCtx.destination);
      this._audioWired = true;
    } catch (err) {
      // No analyser: the core simply won't pulse. Speech still plays.
      this.analyser = null;
      this._audioWired = true;
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
    // RMS, lifted with a curve so quiet speech still reads visually.
    return Math.min(1, Math.sqrt(sum / this._bins.length) * 3.2);
  }

  _endSpeak() {
    if (!this._speaking) return;
    this._speaking = false;
    this._speakStarted = false;
    this.amplitude = 0;
    this.onEvent('speak.ended', {});
  }

  // ------------------------------------------------------------ public API

  setState(state) {
    if (!STATE_PARAMS[state]) return;
    this.state = state;
  }

  setThinking(active) {
    this.thinking = !!active;
  }

  setMicLevel(level) {
    this.micLevel = THREE.MathUtils.clamp(level || 0, 0, 1);
  }

  /**
   * Point the head at someone.
   * @param {number} x  normalised horizontal position, -1 (left) to 1 (right)
   * @param {number} y  normalised vertical position, -1 (down) to 1 (up)
   */
  setGaze(x, y = 0) {
    this.gazeTarget.x = THREE.MathUtils.clamp(x, -1, 1);
    this.gazeTarget.y = THREE.MathUtils.clamp(y, -1, 1);
  }

  /** Convert a CodeProject.AI bounding box into a gaze target. */
  setGazeFromBox(box, frameWidth, frameHeight) {
    const cx = (box.x_min + box.x_max) / 2;
    const cy = (box.y_min + box.y_max) / 2;
    this.setGaze((cx / frameWidth) * 2 - 1, -((cy / frameHeight) * 2 - 1));
  }

  speak(audioUrl) {
    this._ensureAnalyser();
    if (this.audioCtx && this.audioCtx.state === 'suspended') this.audioCtx.resume();
    this._speaking = true;
    this._speakStarted = false;
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
    let vendor = 'unknown';
    try {
      const gl = this.renderer.getContext();
      const ext = gl.getExtension('WEBGL_debug_renderer_info');
      if (ext) {
        vendor = gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) || vendor;
      } else {
        vendor = gl.getParameter(gl.VENDOR) || vendor;
      }
    } catch (_) {
      /* ignore */
    }
    return {
      headLoaded: this.headLoaded,
      webglVendor: vendor,
      fps: Math.round(this._fps || 0),
    };
  }

  dispose() {
    this.renderer.setAnimationLoop(null);
    window.removeEventListener('resize', this._onResize);
    this.renderer.dispose();
  }

  // ----------------------------------------------------------------- loop

  _resize() {
    const w = this.canvas.clientWidth || window.innerWidth;
    const h = this.canvas.clientHeight || window.innerHeight;
    this.renderer.setSize(w, h, false);
    this.camera.aspect = w / h;
    // Portrait panels need a slightly wider vertical FOV so the head fills the frame.
    this.camera.fov = w < h ? 36 : 28;
    this.camera.updateProjectionMatrix();
  }

  _frame() {
    const dt = Math.min(this.clock.getDelta(), 0.1);
    this.t += dt;
    this._fps = this._fps ? this._fps * 0.9 + (1 / dt) * 0.1 : 1 / dt;

    const target = STATE_PARAMS[this.state];
    const k = 1 - Math.exp(-STATE_DAMPING * dt);
    for (const key of Object.keys(target)) {
      this.cur[key] += (target[key] - this.cur[key]) * k;
    }

    if (this.state === 'responding' && this._speaking) {
      this.amplitude += (this._readAmplitude() - this.amplitude) * 0.35;
    } else if (this.state !== 'responding') {
      this.amplitude *= 0.9;
    }

    // Ambient breathes; every other state holds still.
    const breathe = 1 + Math.sin(this.t * 0.4) * 0.03 * this.cur.sway;

    // Listening turns the outer ring into a level meter by scaling the halo.
    const listenPulse = this.state === 'listening' ? this.micLevel * 0.10 : 0;

    // Thinking counter-rotates the halo against the core.
    const spin = this.cur.ringSpin * dt;
    this.core.rotation.z += spin;
    this.halo.rotation.z -= spin * (this.thinking ? 1.8 : 0.5);

    const s = this.cur.scale * breathe;
    this.core.scale.setScalar(s * (1 + this.amplitude * 0.16));
    this.halo.scale.setScalar(s * (1 + this.amplitude * 0.30 + listenPulse));
    this.core.material.opacity = Math.min(1, this.cur.opacity + this.amplitude * 0.4);
    this.halo.material.opacity = Math.min(0.9, this.cur.opacity * 0.28 + this.amplitude * 0.45 + listenPulse * 2);

    this.keyLight.intensity = 0.25 + this.cur.keyLight * 1.45;
    this.rimLight.intensity = 0.3 + this.cur.keyLight * 0.9;

    // Gaze, damped so the head eases rather than snapping.
    const g = 1 - Math.exp(-GAZE_DAMPING * dt);
    this.gaze.x += (this.gazeTarget.x - this.gaze.x) * g;
    this.gaze.y += (this.gazeTarget.y - this.gaze.y) * g;

    const idleYaw = Math.sin(this.t * 0.23) * 0.04 * this.cur.sway;
    const idlePitch = Math.sin(this.t * 0.31) * 0.02 * this.cur.sway;
    this.headGroup.rotation.y = this.gaze.x * MAX_YAW + idleYaw;
    this.headGroup.rotation.x = -this.gaze.y * MAX_PITCH + idlePitch;

    this.renderer.render(this.scene, this.camera);
  }
}
