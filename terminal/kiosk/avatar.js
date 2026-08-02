const SPEAK_STUB_MS = 1500;

export class Avatar {
  constructor({ onSpeakStarted, onSpeakEnded } = {}) {
    this.onSpeakStarted = onSpeakStarted ?? (() => {});
    this.onSpeakEnded = onSpeakEnded ?? (() => {});
    this._speakTimer = null;
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
        console.info('[avatar] config received', envelope.data);
        break;
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

  _speak(data) {
    this._cancel();
    console.info('[avatar] speak stub', data);
    this.onSpeakStarted();
    this._speakTimer = setTimeout(() => {
      this._speakTimer = null;
      this.onSpeakEnded();
    }, SPEAK_STUB_MS);
  }

  _cancel() {
    if (this._speakTimer) {
      clearTimeout(this._speakTimer);
      this._speakTimer = null;
      this.onSpeakEnded();
    }
  }
}
