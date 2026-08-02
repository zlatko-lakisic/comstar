const ENVELOPE_VERSION = 1;

function newId(prefix) {
  return `${prefix}_${crypto.randomUUID()}`;
}

export function wrapMessage(type, data = {}, turnId = null) {
  return JSON.stringify({
    v: ENVELOPE_VERSION,
    id: newId('msg'),
    type,
    ts: Date.now(),
    turn_id: turnId,
    data,
  });
}

export class BridgeClient {
  constructor(url, { onStateChange, onEnvelope, onOpen } = {}) {
    this.url = url;
    this.onStateChange = onStateChange ?? (() => {});
    this.onEnvelope = onEnvelope ?? (() => {});
    this.onOpen = onOpen ?? (() => {});
    this.ws = null;
    this._attempt = 0;
    this._stopped = false;
    this._minBackoff = 500;
    this._maxBackoff = 5000;
  }

  connect() {
    if (this._stopped) return;
    this.onStateChange('connecting');
    this.ws = new WebSocket(this.url);

    this.ws.addEventListener('open', () => {
      this._attempt = 0;
      this.onStateChange('connected');
      this.onOpen();
    });

    this.ws.addEventListener('message', (event) => {
      let envelope;
      try {
        envelope = JSON.parse(event.data);
      } catch {
        console.warn('[kiosk] malformed message');
        return;
      }
      if (envelope.type === 'ping') {
        this.send('pong');
        return;
      }
      this.onEnvelope(envelope);
    });

    this.ws.addEventListener('close', () => {
      this.onStateChange('disconnected');
      this._scheduleReconnect();
    });

    this.ws.addEventListener('error', () => {
      this.ws?.close();
    });
  }

  _scheduleReconnect() {
    if (this._stopped) return;
    this._attempt += 1;
    const base = Math.min(
      this._maxBackoff,
      this._minBackoff * 2 ** (this._attempt - 1),
    );
    const jitter = Math.random() * base * 0.2;
    setTimeout(() => this.connect(), base + jitter);
  }

  send(type, data = {}, turnId = null) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    this.ws.send(wrapMessage(type, data, turnId));
  }

  stop() {
    this._stopped = true;
    this.ws?.close();
  }
}
