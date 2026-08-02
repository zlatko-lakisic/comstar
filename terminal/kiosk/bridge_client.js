/**
 * Bridge client for the COMSTAR kiosk.
 *
 * Speaks the envelope defined in docs/CONTRACTS.md §1. Unknown message types
 * are logged and dropped, never thrown, so the bridge and the kiosk can ship
 * independently of one another.
 *
 * Production connects to ws://127.0.0.1:8777/kiosk. In dev mode the bridge runs
 * on the Mac and the URL comes from ?bridge= (see docs/DEV_LOOP.md §1, Loop B).
 */

const PROTOCOL_VERSION = 1;
const BACKOFF_BASE_MS = 250;
const BACKOFF_MAX_MS = 5000;

function ulid() {
  const t = Date.now().toString(36).toUpperCase().padStart(10, '0');
  let r = '';
  for (let i = 0; i < 16; i++) {
    r += '0123456789ABCDEFGHJKMNPQRSTVWXYZ'[(Math.random() * 32) | 0];
  }
  return `msg_${t}${r}`;
}

export class BridgeClient {
  constructor(url, handlers = {}) {
    this.url = url;
    this.handlers = handlers;
    this.turnId = null;
    this.attempt = 0;
    this.ws = null;
    this.closed = false;
    this._connect();
  }

  _connect() {
    if (this.closed) return;
    try {
      this.ws = new WebSocket(this.url);
    } catch (err) {
      this._scheduleReconnect();
      return;
    }

    this.ws.addEventListener('open', () => {
      this.attempt = 0;
      if (this.handlers.onOpen) this.handlers.onOpen();
    });

    this.ws.addEventListener('message', (ev) => {
      let msg;
      try {
        msg = JSON.parse(ev.data);
      } catch {
        console.warn('[bridge] malformed JSON dropped');
        return;
      }
      if (msg.v !== PROTOCOL_VERSION) {
        console.warn('[bridge] unsupported envelope version', msg.v);
        return;
      }
      if (msg.type === 'ping') {
        this.send('pong');
        return;
      }
      this.turnId = msg.turn_id ?? null;
      const fn = this.handlers[msg.type];
      if (!fn) {
        console.info('[bridge] unhandled type dropped:', msg.type);
        return;
      }
      try {
        fn(msg.data || {}, msg);
      } catch (err) {
        console.error('[bridge] handler threw', msg.type, err);
      }
    });

    this.ws.addEventListener('close', () => {
      if (this.handlers.onClose) this.handlers.onClose();
      this._scheduleReconnect();
    });

    this.ws.addEventListener('error', () => {
      try {
        this.ws.close();
      } catch {
        /* already closing */
      }
    });
  }

  _scheduleReconnect() {
    if (this.closed) return;
    const capped = Math.min(BACKOFF_BASE_MS * 2 ** this.attempt, BACKOFF_MAX_MS);
    const jittered = capped * (0.5 + Math.random() * 0.5);
    this.attempt += 1;
    setTimeout(() => this._connect(), jittered);
  }

  send(type, data = {}) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return false;
    this.ws.send(
      JSON.stringify({
        v: PROTOCOL_VERSION,
        id: ulid(),
        type,
        ts: Date.now(),
        turn_id: this.turnId,
        data,
      }),
    );
    return true;
  }

  span(name, ms) {
    this.send('span', { name, ms: Math.round(ms) });
  }

  close() {
    this.closed = true;
    if (this.ws) this.ws.close();
  }
}
