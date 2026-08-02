/**
 * Avatar / speak handler.
 * Phase 1: play bridge audioUrl via HTMLAudioElement and emit speak.started/ended
 * for follow-up window timing. TalkingHead GLB lip-sync lands when a model is present.
 */
export class Avatar {
  constructor({ root, onSpeakStarted, onSpeakEnded } = {}) {
    this.root = root ?? document.body;
    this.onSpeakStarted = onSpeakStarted ?? (() => {});
    this.onSpeakEnded = onSpeakEnded ?? (() => {});
    this._audio = null;
    this._fallbackTimer = null;
    this.loaded = true;
    this.webglVendor = this._detectWebgl(this.root);
  }

  _detectWebgl(mount) {
    try {
      const c = document.createElement('canvas');
      mount?.appendChild?.(c);
      const gl = c.getContext('webgl') || c.getContext('experimental-webgl');
      if (!gl) return 'none';
      const dbg = gl.getExtension('WEBGL_debug_renderer_info');
      const vendor = dbg
        ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL)
        : 'webgl';
      c.remove();
      return vendor;
    } catch (_) {
      return 'error';
    }
  }

  handle(envelope) {
    switch (envelope.type) {
      case 'speak':
        this._speak(envelope.data ?? {});
        break;
      case 'speak.cancel':
        this._cancel();
        break;
      case 'config':
      case 'state':
      case 'listening':
      case 'thinking':
      case 'error':
        console.info('[avatar]', envelope.type, envelope.data);
        break;
      default:
        console.warn('[avatar] unknown type ignored', envelope.type);
    }
  }

  async _speak(data) {
    this._cancel(false);
    const url = data.audioUrl;
    this.onSpeakStarted();

    if (!url) {
      this._fallbackTimer = setTimeout(() => {
        this._fallbackTimer = null;
        this.onSpeakEnded();
      }, 1200);
      return;
    }

    try {
      const audio = new Audio(url);
      this._audio = audio;
      audio.onended = () => {
        this._audio = null;
        this.onSpeakEnded();
      };
      audio.onerror = () => {
        this._audio = null;
        this.onSpeakEnded();
      };
      await audio.play();
    } catch (err) {
      console.warn('[avatar] play failed', err);
      this._audio = null;
      this.onSpeakEnded();
    }
  }

  _cancel(emitEnded = true) {
    if (this._fallbackTimer) {
      clearTimeout(this._fallbackTimer);
      this._fallbackTimer = null;
    }
    if (this._audio) {
      try {
        this._audio.pause();
        this._audio.src = '';
      } catch (_) {}
      this._audio = null;
      if (emitEnded) this.onSpeakEnded();
    }
  }
}
