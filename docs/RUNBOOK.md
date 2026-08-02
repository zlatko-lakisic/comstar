# COMSTAR Runbook

Operational guide for the COMSTAR terminal (Phase 1).  
Hardware baseline: `docs/BASELINES.md`. Dev workflow: `docs/DEV_LOOP.md`.

---

## Pi layout

| Path | Purpose |
|---|---|
| `/opt/comstar/src` | Deployed git tree (rsync target) |
| `/opt/comstar/config/comstar.yaml` | Production config (not in repo) |
| `/opt/comstar/models/` | Wake-word ONNX, avatar GLB (not in repo) |
| `~/.config/systemd/user/` | User units: `comstar-bridge`, `comstar-audio`, `comstar-kiosk` |

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

Defaults: camera `/dev/video0`, CPAI `http://10.0.10.16:32168`. Override with
`COMSTAR_CAMERA_DEVICE`, `CPAI_URL`, or `COMSTAR_ENROLL_DIR`.

Verify with CPAI face list:

```bash
curl -sS -X POST http://10.0.10.16:32168/v1/vision/face/list | jq .
```

---

## 2. Start the three processes

### Production (Pi, user systemd)

Ensure `loginctl enable-linger md-admin` is set once, then:

```bash
systemctl --user enable --now comstar-bridge comstar-audio comstar-kiosk
systemctl --user status comstar-bridge comstar-audio comstar-kiosk
```

Unit files live in `deploy/systemd/`. Copy or symlink into
`~/.config/systemd/user/` and adjust paths if not using `/opt/comstar/src`.

### Development (Mac)

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

## 3. Speech-to-text (`COMSTAR_STT_URL`)

The bridge reads `COMSTAR_STT_URL` and POSTs WAV to
`$COMSTAR_STT_URL/v1/audio/transcriptions`.

### Local dev server (faster-whisper)

```bash
python3 -m venv .venv-stt && source .venv-stt/bin/activate
pip install -r scripts/requirements-stt.txt
make stt-dev
# or: python scripts/stt_server.py
```

Set on the bridge:

```bash
export COMSTAR_STT_URL=http://127.0.0.1:8090
```

If faster-whisper is not installed, `stt_server.py` exits with a clear error.

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
- **Audio:** utterances are streamed to STT on the LAN (`COMSTAR_STT_URL`); ring buffer
  is in-memory only (never written to disk by default).
- **Orchestration:** AO Reach on the LAN; guest/restricted mode limits MCP tools.

**Immediate stop:**

```bash
systemctl --user stop comstar-bridge comstar-audio comstar-kiosk
```

**Disable auto-start:**

```bash
systemctl --user disable comstar-bridge comstar-audio comstar-kiosk
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
| STT | `127.0.0.1:8090` | `curl http://127.0.0.1:8090/health` |
| AO Reach | `10.0.10.16:8765` | `spike/reach_hello.dart` |
| CodeProject.AI | `10.0.10.16:32168` | `scripts/verify_cpai.sh` |

---

## 9. Common failures

| Symptom | Likely cause | Fix |
|---|---|---|
| Empty STT transcript | `COMSTAR_STT_URL` unset or STT down | Start `make stt-dev`, export URL |
| Wake never fires | Stub model / missing ONNX | Train & deploy wake model (M4) |
| Kiosk silent | Bridge not running or wrong `bridge=` URL | Check WS on :8777 |
| No greet-by-name | Face not enrolled | `enroll_face.sh` |
| AO timeout | AI server unreachable | Check `10.0.10.16:8765`, overlay path |

## Local STT note

Use Python **3.12** for `.venv-stt` (`faster-whisper` / PyAV do not build on 3.14 yet):

```bash
/usr/local/bin/python3.12 -m venv .venv-stt
source .venv-stt/bin/activate
pip install -r scripts/requirements-stt.txt
make stt-dev
export COMSTAR_STT_URL=http://127.0.0.1:8090
```
