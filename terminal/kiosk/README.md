# COMSTAR Kiosk

Phase 1 kiosk shell: WebSocket client to the bridge, HTMLAudioElement playback, and a
full-bleed `#avatar` container for a future TalkingHead GLB.

## Run locally

```bash
cd terminal/kiosk
npm start
```

Serves on **http://127.0.0.1:5173/** (via `npx serve`).

## Point Chromium at it

**Desktop / dev (Mac):**

```bash
open "http://127.0.0.1:5173/?bridge=ws://127.0.0.1:8777/kiosk"
```

**Pi panel (production or LAN dev):**

```bash
chromium-browser --kiosk --noerrdialogs \
  "http://127.0.0.1:5173/?bridge=ws://127.0.0.1:8777/kiosk"
```

When the bridge runs on another host (see `docs/DEV_LOOP.md` Loop A), set `bridge` to
that host, e.g.:

```
http://comstar-dev.lan:5173/?bridge=ws://comstar-dev.lan:8777/kiosk
```

## Bridge messages

| Inbound (bridge → kiosk) | Action |
|---|---|
| `speak` | Play `data.audioUrl` via HTMLAudioElement; emit `speak.started` / `speak.ended` |
| `speak.cancel` | Stop playback immediately |
| `state`, `listening`, `thinking`, `config` | Logged (visuals in M7) |

| Outbound (kiosk → bridge) | When |
|---|---|
| `ready` | WebSocket open |
| `speak.started` | Audio playback begins |
| `speak.ended` | Playback finished or cancelled |

## Systemd

See `deploy/systemd/comstar-kiosk.service`. For hot reload during development, point
Chromium at a dev server on your Mac instead of the local `file://` URL.
