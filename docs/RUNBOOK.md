# COMSTAR Runbook

Operational guide for the COMSTAR terminal (Phase 1).  
Hardware baseline: `docs/BASELINES.md`. Dev workflow: `docs/DEV_LOOP.md`.

---

## Pi layout

| Path | Purpose |
|---|---|
| `/opt/comstar/src` | Deployed git tree (rsync target) |
| `/opt/comstar/src/config/comstar.yaml` | Production config (created from example on first deploy; not in git) |
| `/opt/comstar/src/models/` | Wake-word ONNX, avatar GLB (not in repo) |
| SSH `comstar` | `md-admin@192.168.89.34` (key auth) |
| Local TTS | Optional fallback: `comstar-tts` on `127.0.0.1:8091` (Piper via sherpa-onnx) |
| Local STT | Optional fallback: `comstar-stt` on `127.0.0.1:8090` (faster-whisper) |
| Production speech | Prefer AO-advertised sidecars on Ada (Reach `SpeechClient`); see §3 |
| Local speaker | `COMSTAR_LOCAL_SPEAKER=1` plays via `paplay` when kiosk absent |
| Camera source | `COMSTAR_CAMERA_SOURCE` (alias: `COMSTAR_CAMERA_INPUT`) — e.g. `/dev/video0` |
| Mic source | `COMSTAR_MIC_SOURCE` — sounddevice index or name substring (e.g. `C525`) |
| Speaker source | `COMSTAR_SPEAKER_SOURCE` — Pulse/PipeWire sink for local `paplay` |
| `~/.config/systemd/user/` | User units: `comstar-bridge`, `comstar-audio`, `comstar-kiosk`, `comstar-stt`, `comstar-tts` |

Deploy from the Mac:

```bash
make deploy
# or: bash deploy/deploy.sh
```

---

## 1. Enroll a face

On the Pi (or any host with the terminal camera and CPAI reachability):

```bash
cd /opt/comstar/src
./scripts/enroll_face.sh <userid>
```

Defaults: camera `/dev/video0` (`COMSTAR_CAMERA_SOURCE`), CPAI `http://10.0.10.16:32168`.
Override with `COMSTAR_CAMERA_SOURCE`, `CPAI_URL`, or `COMSTAR_ENROLL_DIR`.

Verify with CPAI face list:

```bash
curl -sS -X POST http://10.0.10.16:32168/v1/vision/face/list | jq .
```

---

## 2. Start the three processes

### Production (Pi, user systemd)

Ensure `loginctl enable-linger md-admin` is set once, then:

```bash
# Prefer Reach speech when Ada advertises hello.speech (AO ≥ 1.28).
# Local STT/TTS units are optional fallback / Mac bring-up:
systemctl --user enable --now comstar-bridge comstar-audio comstar-kiosk
# Optional until Ada speech is proven:
# systemctl --user enable --now comstar-stt comstar-tts
systemctl --user status comstar-bridge comstar-audio comstar-kiosk
```

Unit files live in `deploy/systemd/`. Copy or symlink into
`~/.config/systemd/user/` and adjust paths if not using `/opt/comstar/src`.

### Development (Mac — browser loop)

Speech and peripherals can run entirely on the Mac for bring-up (no Pi required):

```bash
# Optional device picks (gitignored local file)
cp config/comstar.mac.env.example config/comstar.mac.env
# edit camera/mic/speaker, then:
set -a && source config/comstar.mac.env && set +a

# Terminal 1 — STT (faster-whisper)
make stt-dev
export COMSTAR_STT_URL=http://127.0.0.1:8090

# Terminal 2 — TTS (optional for spoken replies)
python3 scripts/tts_server.py   # or systemd-equivalent on Pi

# Terminal 3 — bridge (dev config; bind_lan false for localhost browser)
COMSTAR_ENV=dev make bridge-dev

# Terminal 4 — kiosk
make kiosk-dev
# Open Chrome: http://127.0.0.1:5173/?bridge=ws://127.0.0.1:8777/kiosk
```

Notes:

- The kiosk UI does **not** show a live camera preview. Camera ownership is in the bridge (`ffmpeg`).
- Overlay paths are cwd-relative — start the bridge from the repo root (or set absolute `overlay_root`).
- Keep `config/comstar.mac.env` out of git (already gitignored).

### Development (Mac bridge + Pi audio)

```bash
# Terminal 1 — bridge (dev config, optional LAN bind)
COMSTAR_ENV=dev make bridge-dev

# Terminal 2 — kiosk dev server
make kiosk-dev
# Point Chromium at http://127.0.0.1:5173/?bridge=ws://127.0.0.1:8777/kiosk

# Terminal 3 — audio (on Pi; see DEV_LOOP Loop C)
make audio-sync
```

---

## 3. Speech (STT + TTS)

**Preferred (production):** AO ≥ 1.28 advertises speech on WebSocket `hello`. After
`SessionBridge.start`, the bridge uses `speechClient.transcribe` /
`speechClient.synthesize` (OpenAI-compatible HTTP to Ada sidecars). See
`docs/adr/0003-speech-on-ada.md`.

On the AI server (same host as AO `:8765`):

```bash
# Sidecars — see vendor AO speech/README.md
python speech/stt_server.py --host 0.0.0.0 --port 8090 --model base --device cuda
AGENTIC_SPEECH_TTS_MODEL_DIR=… python speech/tts_server.py --host 0.0.0.0 --port 8091

# Engine env (restart orchestration.serve)
export AGENTIC_SPEECH_ENABLED=1
export AGENTIC_SPEECH_ADVERTISE_STT_URL=http://<ada-lan-ip>:8090
export AGENTIC_SPEECH_ADVERTISE_TTS_URL=http://<ada-lan-ip>:8091
# optional: AGENTIC_SPEECH_TOKEN=...
```

Confirm WS `hello` includes `"speech": { "enabled": true, "sttBaseUrl": "...", "ttsBaseUrl": "..." }`.

**Fallback (Mac / offline / speech disabled on AO):**

| Service | Unit | Port | Script |
|---|---|---|---|
| STT | `comstar-stt` | `127.0.0.1:8090` | `scripts/stt_server_whisper.py --model tiny --beam-size 5` |
| TTS | `comstar-tts` | `127.0.0.1:8091` | `scripts/tts_server.py` |

The bridge uses `$COMSTAR_STT_URL` / `$COMSTAR_TTS_URL` when `speechClient == null`.
Optional `COMSTAR_SPEECH_TOKEN` (or `AGENTIC_SPEECH_TOKEN`) for sidecar bearer auth.

Live path (what product accuracy means):

```
mic → comstar-audio (VAD) → bridge PCM → Reach SpeechClient or HttpSttClient → transcript
```

STT is **batch after VAD end**, not streaming. Debug WAV: `/tmp/comstar-last-utterance.wav`.
Pi archive: `/opt/comstar/testdata/stt/live/`.

### Local / Mac STT server

```bash
# Prefer Python 3.12 (.venv-stt) — PyAV/faster-whisper struggle on 3.14
python3.12 -m venv .venv-stt && source .venv-stt/bin/activate
pip install -r scripts/requirements-stt.txt
make stt-dev
# → scripts/stt_server_whisper.py (production engine)
# Alternate: scripts/stt_server.py (Moonshine) — not used live
export COMSTAR_STT_URL=http://127.0.0.1:8090
curl -sS http://127.0.0.1:8090/health
```

### STT fixture testing

```bash
# Offline metadata / engine smoke
python3 -m unittest discover -s testdata/stt -p 'test_*.py'

# Live accuracy gate (needs ≥ N labeled bridge fixtures)
COMSTAR_STT_BENCH=1 python3 -m testdata.stt.bench_stt --trials 1 --require-live 10
```

Each labeled fixture is a `*.wav` + sibling `*.json`:

```json
{
  "file": "utterance.wav",
  "transcript": "How are you doing today",
  "source": "bridge",
  "path": "audio→bridge→stt"
}
```

`source: parecord` (or synthetic) fixtures are fine for smoke checks but **do not
count** toward the live gate. Replaying one golden file ten times only proves
determinism — it is not a product accuracy test.

### Device env vars

| Variable | Role |
|---|---|
| `COMSTAR_CAMERA_SOURCE` | ffmpeg camera (`/dev/video0`, `avfoundation:N`) |
| `COMSTAR_MIC_SOURCE` | sounddevice index or name substring |
| `COMSTAR_SPEAKER_SOURCE` | Pulse/PipeWire sink for `paplay` |
| `COMSTAR_VAD_SILENCE_MS` | end-of-speech silence (Pi often uses `1200`) |

---

## 4. Train wake word (placeholder)

Full training is M4.2. Until the openWakeWord pipeline is provisioned:

```bash
python scripts/train_wakeword.py --phrase "hey comstar" \
  --out terminal/audio/models/hey_comstar.onnx
```

Without `openwakeword[train]`, the script prints setup instructions and exits.
The audio process uses a stub wake detector that never fires until a real ONNX
model is deployed to `models/hey_comstar.onnx` (or the path in config).

---

## 5. Dev event injection

When `COMSTAR_ENV=dev`, the bridge serves **POST http://127.0.0.1:8779/inject**:

```json
{"event": "TranscriptReady", "text": "What time is it?"}
```

Supported events: `PersonDetected`, `PersonAbsent`, `FaceRecognized`,
`FaceUnknown`, `WakeWord`, `SpeechStart`, `SpeechEnd`, `TranscriptReady`,
`ResponseReady`, `PlaybackEnded`, `Tick`, `AttentionError`, `VisionDegraded`,
`VisionRecovered`.

Injected events are logged with `src: injected`. A full dev console UI is planned
(M3.7); this endpoint is the minimal harness.

---

## 6. Rollback

If using symlinked releases (`docs/DEV_LOOP.md` §9):

```bash
ssh comstar 'ln -sfn /opt/comstar/releases/PREVIOUS /opt/comstar/current && \
  systemctl --user restart comstar-bridge comstar-audio comstar-kiosk'
```

For rsync deploys to `/opt/comstar/src`, redeploy a known-good commit:

```bash
git checkout <good-sha>
make deploy
```

---

## 7. Privacy kill switch

COMSTAR is designed for local-first operation:

- **Vision:** frames go to CodeProject.AI on the LAN only; no cloud upload in Phase 1.
- **Audio:** wake/VAD stay on-Pi; utterance PCM goes to the STT in use — Ada sidecars
  when Reach `speechClient` is set, else `COMSTAR_STT_URL` (often local `127.0.0.1:8090`).
  Ring buffer is in-memory only (never written to disk by default). Live archives under
  `/opt/comstar/testdata/stt/live/` are optional debug captures.
- **Orchestration:** AO Reach on the LAN; guest/restricted mode limits MCP tools.

**Immediate stop:**

```bash
systemctl --user stop comstar-bridge comstar-audio comstar-kiosk comstar-stt comstar-tts
```

**Disable auto-start:**

```bash
systemctl --user disable comstar-bridge comstar-audio comstar-kiosk comstar-stt comstar-tts
```

**Network isolation:** unplug Ethernet / disable Wi-Fi on the Pi to confirm offline
fallback lines still play (M6 exit criterion).

Production configs must ship with `dev.bind_lan: false`. LAN WebSocket bind requires
all three gates: `COMSTAR_ENV=dev`, `comstar.dev.yaml`, and non-empty `dev.lan_token`.

---

## 8. Health checks

```bash
make doctor          # local toolchain + optional LAN service probes
make test            # Dart + Python unit tests
make logs            # merged journal tail (when configured)
```

| Service | Default | Check |
|---|---|---|
| Bridge WS (kiosk) | `127.0.0.1:8777` | kiosk connects, `ready` logged |
| Bridge WS (audio) | `127.0.0.1:8778` | audio process connects |
| Dev inject | `127.0.0.1:8779` | dev only |
| STT | Ada `:8090` or local | `curl http://<stt-host>:8090/health`; bridge log `speech_reach` vs `speech_fallback` |
| TTS | Ada `:8091` or local | `curl http://<tts-host>:8091/health` (or POST `/v1/audio/speech`) |
| AO Reach | `10.0.10.16:8765` | `spike/reach_hello.dart` |
| CodeProject.AI | `10.0.10.16:32168` | `scripts/verify_cpai.sh` |

---

## 9. Common failures

| Symptom | Likely cause | Fix |
|---|---|---|
| Empty / junk STT | STT down, wrong engine, or short utterance | Check Ada speech `/health` or `systemctl --user status comstar-stt`; `/tmp/comstar-last-utterance.wav`; raise finalize threshold |
| Fast speech cut early | VAD silence too aggressive | Raise `COMSTAR_VAD_SILENCE_MS` (e.g. 1200); hysteresis is in `terminal/audio/vad.py` |
| Empty STT on Mac | `COMSTAR_STT_URL` unset or STT down | `make stt-dev`, export URL |
| Wake never fires | Stub model / missing ONNX | Train ONNX, or `COMSTAR_FORCE_WAKE_SCORE=0.99`, or inject `WakeWord` on `:8779` |
| Kiosk blank / no WS | Chromium not loading `http://127.0.0.1:8776/kiosk/` | Confirm bridge `:8776` up; restart `comstar-kiosk`; avoid `file://` |
| Kiosk silent | Bridge not running or wrong `bridge=` URL | Check WS on :8777 |
| Chrome has no camera preview | Expected — kiosk has no webcam tile | Confirm bridge ffmpeg / camera LED; set `COMSTAR_CAMERA_SOURCE` |
| No greet-by-name | Face not enrolled | `enroll_face.sh` |
| AO timeout / overlay missing | AI server unreachable or cwd-relative overlay | Check `10.0.10.16:8765`; run bridge from repo root or absolute `overlay_root` |
| Google tools missing | Not paired / guest / MCP soft-skip | Say “connect my Google”; check `GOOGLE_CLIENT_*` env; tokens under `~/.local/share/comstar/google/`; preinstall `npm install --prefix ~/.local mcp-server-google-workspace@0.2.6` so bridge can use local `node dist` (nested `npx` often misses the ready window on Pi) |
| Pairing QR never shows | Kiosk outdated / `pairing.qr` dropped | Redeploy `terminal/kiosk/`; confirm bridge logs `google_pairing_start` |
| Linked but “no internet/search” | Tools MCP not registered, or ask is web search | Status: “Workspace tools …”; voice Google is Calendar/`drive.file` (not Google Search). Check bridge `mcp_overlay_ready` vs `mcp_overlay_bootstrap` |

## 10. Google Workspace (mail / calendar / Drive)

Comstar does **not** ship a custom Gmail MCP. It pairs once (voice + QR), stores a
per-userid refresh token, runs pinned `mcp-server-google-workspace` via
`LocalMcpHost.startNpxPackage`, and tunnels it to AO as `client.google_workspace`.

Preinstall on the bridge host (avoids slow nested `npx` on session open).
Requires **Node.js ≥20** (global `crypto`; mcp-proxy 5.12+):

```bash
# Debian/Pi example (NodeSource 20.x), then:
npm install --prefix ~/.local mcp-server-google-workspace@0.2.6
bash scripts/patch_google_mcp_schema.sh   # CrewAI rejects union JSON Schema types
node -v   # must be v20+
```

Live connectivity (read-only prompts):

```bash
bash scripts/google_workspace_e2e.sh
# AO + tunnel (from terminal/bridge):
#   dart run tool/google_workspace_ao_e2e.dart
```

1. Create a Google Cloud OAuth client (**TVs and Limited Input devices**). Enable
   Calendar and Drive APIs. Device-code pairing cannot request Gmail scopes
   (Google returns `invalid_scope`); voice+QR grants Calendar + `drive.file`.
   For full Gmail access, mint a refresh token once with the Desktop client
   (OAuth Playground) and place it in `~/.local/share/comstar/google/<userid>.json`.
2. Export `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` on the bridge host
   (Pi: `~/.config/comstar/google.env` via systemd drop-in; Mac:
   `config/comstar.mac.env`). Never commit them.
3. As a known face, say **“connect my Google”**. Enter the spoken code on your
   phone or scan the on-screen QR.
4. Tokens land in `~/.local/share/comstar/google/<userid>.json` (`0600`).
5. Voice agent allowlist: `overlays/comstar/agent_providers/voice_responder.yaml`
   → `client.google_workspace`. Guests never get Google tools.
6. Unlink: say **“disconnect Google”**. Soft-fail if tokens are revoked — voice
   still works; say connect again.

“Check Google” / web search is **not** a Workspace tool. Ask for calendar events
or Drive files that the linked account can access.

Mac spike (optional, with a refresh token already in env):

```bash
GOOGLE_CLIENT_ID=… GOOGLE_CLIENT_SECRET=… GOOGLE_REFRESH_TOKEN=… \
  npx -y mcp-server-google-workspace@0.2.6
```

## Local STT note

Use Python **3.12** for `.venv-stt` (`faster-whisper` / PyAV do not build on 3.14 yet):

```bash
/usr/local/bin/python3.12 -m venv .venv-stt
source .venv-stt/bin/activate
pip install -r scripts/requirements-stt.txt
make stt-dev
export COMSTAR_STT_URL=http://127.0.0.1:8090
```
