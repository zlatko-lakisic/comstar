(function (global) {
  /**
   * Avatar / speak handler — HTMLAudioElement path (TalkingHead GLB later).
   */
  class Avatar {
    constructor({ root, onSpeakStarted, onSpeakEnded } = {}) {
      this.root = root ?? document.body;
      this.onSpeakStarted = onSpeakStarted ?? (() => {});
      this.onSpeakEnded = onSpeakEnded ?? (() => {});
      this._audio = null;
      this._fallbackTimer = null;
      this.loaded = true;
      this.webglVendor = this._detectWebgl(this.root);
      this._state = 'ambient';
      this._listening = false;
      this._thinking = false;
      this._stage = this._ensureStage();
    }

    _ensureStage() {
      let stage = this.root.querySelector?.('.avatar-stage');
      if (!stage) {
        stage = document.createElement('div');
        stage.className = 'avatar-stage';
        stage.style.cssText =
          'position:absolute;inset:0;display:flex;align-items:center;justify-content:center;' +
          'transition:background 280ms ease, opacity 280ms ease;';
        const orb = document.createElement('div');
        orb.className = 'avatar-orb';
        orb.style.cssText =
          'width:min(42vw,280px);height:min(42vw,280px);border-radius:50%;' +
          'background:radial-gradient(circle at 35% 30%, #7dd3fc 0%, #1d4ed8 45%, #0b0f14 75%);' +
          'box-shadow:0 0 60px rgba(56,189,248,0.25);transition:transform 220ms ease, filter 220ms ease;';
        stage.appendChild(orb);
        this.root.appendChild?.(stage);
      }
      return stage;
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

    _paint() {
      const orb = this._stage?.querySelector?.('.avatar-orb');
      if (!orb) return;
      let scale = 1;
      let filter = 'saturate(1)';
      if (this._thinking) {
        scale = 1.06;
        filter = 'saturate(1.3) hue-rotate(20deg)';
      } else if (this._listening) {
        scale = 1.1;
        filter = 'saturate(1.4)';
      } else if (this._state === 'engaged' || this._state === 'responding') {
        scale = 1.04;
      }
      orb.style.transform = `scale(${scale})`;
      orb.style.filter = filter;
    }

    handle(envelope) {
      switch (envelope.type) {
        case 'speak':
          this._speak(envelope.data ?? {});
          break;
        case 'speak.cancel':
          this._cancel();
          break;
        case 'state':
          this._state = envelope.data?.state ?? this._state;
          this._paint();
          break;
        case 'listening':
          this._listening = Boolean(envelope.data?.active);
          this._paint();
          break;
        case 'thinking':
          this._thinking = Boolean(envelope.data?.active);
          this._paint();
          break;
        case 'config':
          if (envelope.data?.avatarUrl) {
            console.info('[avatar] GLB url present', envelope.data.avatarUrl);
          }
          break;
        case 'error':
          console.warn('[avatar] error', envelope.data);
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

  global.ComstarAvatar = Avatar;
})(window);
