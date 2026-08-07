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
| Local speaker | `COMSTAR_LOCAL_SPEAKER=1` plays via `paplay` (including when kiosk is connected) |
| Camera source | `COMSTAR_CAMERA_SOURCE` (alias: `COMSTAR_CAMERA_INPUT`) — e.g. `/dev/video0` |
| Mic source | `COMSTAR_MIC_SOURCE` — sounddevice index or name substring (e.g. `C525`) |
| Speaker source | `COMSTAR_SPEAKER_SOURCE` — Pulse/PipeWire sink for local `paplay` |
| Phrase banks | `phrases:` in config — AO-refreshed engage / sleep_enter / sleep_wake / social lines (`~/.cache/comstar/phrase_banks.json`) |
| Conversation memory | `memory:` + `comstar-memory` on `:8792` — rolling chat + durable FTS facts across terminals |
| `~/.config/systemd/user/` | User units: `comstar-bridge`, `comstar-audio`, `comstar-kiosk`, `comstar-stt`, `comstar-tts`, `comstar-health.timer` |

### Health / auto-heal

`scripts/comstar_health.sh` (timer every 2 min) checks units, ports, AO, CPAI, and
bridge `GET http://127.0.0.1:8781/admin/health` (always-on; attention state + kiosk/audio WS).
It also runs `scripts/comstar_audio_health.sh` for PipeWire speaker/mic:

- default sink must be `COMSTAR_SPEAKER_SOURCE` (Pi: `comstar_hdmi`, ACP HDMI-0 renamed)
- primary HDMI (`vc4-hdmi-0`) profile must stay on; headphones + spare HDMI off (dual-open breaks playback)
- default mic present, not a monitor, unmuted

With `COMSTAR_HEALTH_HEAL=1`, after consecutive misses it restarts the PipeWire
stack, re-runs `prefer-hdmi-audio.sh`, and restarts `comstar-audio` (5 min cooldown
between full audio heals). Full admin UI: `http://127.0.0.1:8781/admin/` via SSH
tunnel (`make admin`).

```bash
ssh comstar 'COMSTAR_HEALTH_HEAL=1 bash /opt/comstar/src/scripts/comstar_health.sh'
ssh comstar 'COMSTAR_HEALTH_HEAL=1 bash /opt/comstar/src/scripts/comstar_audio_health.sh'
systemctl --user status comstar-health.timer
```

Deploy from the Mac:

```bash
make deploy
# or: bash deploy/deploy.sh
```

---

## Boot sequence (splash → kiosk)

Desired panel path after a cold boot:

1. **Plymouth** — COMSTAR dark splash + spinner (early kernel / init). One-time:
   `sudo bash /opt/comstar/src/scripts/install-plymouth-comstar.sh`
2. **`comstar-labwc` session** — LightDM autologin into labwc **without**
   `--merge-config`, so Pi `pcmanfm` / `wf-panel-pi` never start. Dark `swaybg`
   then Chromium splash. One-time: `bash /opt/comstar/src/scripts/install-pi-session.sh`
   (or `make pi-session`). This installs the wayland session + LightDM drop-in.
3. **`comstar-kiosk`** — Chromium on `:8769/splash.html` → live kiosk when
   bridge `boot.txt` is ready.

Sources: `terminal/kiosk/splash.html`, `scripts/kiosk-launch.sh`,
`deploy/pi-session/`, `deploy/plymouth/comstar/`. Also `make plymouth` for early boot.

**Debug / temporary Pi desktop:**

```bash
sudo cp /etc/lightdm/lightdm.conf.pre-comstar /etc/lightdm/lightdm.conf
sudo systemctl restart lightdm
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

When AO advertises `hello.speech`, set `COMSTAR_SPEECH_OVERRIDE=1` so those same
URLs (or dedicated `COMSTAR_STT_OVERRIDE` / `COMSTAR_TTS_OVERRIDE`) are passed as
Reach `speechSttBaseUrlOverride` / `speechTtsBaseUrlOverride` after hello parse.
Example (Ada medium.en STT + lessac-high TTS):

```bash
export COMSTAR_SPEECH_OVERRIDE=1
export COMSTAR_STT_URL=http://10.0.10.16:8093
export COMSTAR_TTS_URL=http://10.0.10.16:8092
```

Requires AO Reach ≥ 0.3.0. STT uses `transcribeDetailed`; optional confidence
fields gate low-quality transcripts when the sidecar returns them.
Optional `COMSTAR_SPEECH_TOKEN` (or `AGENTIC_SPEECH_TOKEN`) for sidecar bearer auth.

Live path (what product accuracy means):

```
mic → comstar-audio (VAD) → bridge PCM → Reach SpeechClient or HttpSttClient → transcript
```

STT is **batch after VAD end**, not streaming. Optional debug WAV
(`/tmp/comstar-last-utterance.wav`, Pi `testdata/stt/live/`) only when
`COMSTAR_STT_ARCHIVE=1`.

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

## 4. Train wake word (M4.2) + runtime bypass

**Shipping path today:** no `hey_comstar.onnx` yet. Audio uses energy-gated
**force-wake** (`COMSTAR_FORCE_WAKE_SCORE`, default RMS ~0.08) plus sleep-mode
STT verify (`maxMs` 7500). That is enough for hallway bring-up; it is **not**
the M4 ROC gate.

### Train ONNX (when room data exists)

1. Record ≥50 positive “hey comstar” clips across the room + TV/ads negatives.
2. Provision openWakeWord AutoTrainer (Piper voices + negative corpus + IRs).
3. Run:

```bash
python scripts/train_wakeword.py --phrase "hey comstar" \
  --out models/hey_comstar.onnx
```

Until AutoTrainer is assembled, the script exits `2` and prints bypasses.
Deploy the ONNX next to the audio process (`models/hey_comstar.onnx` or the
path in config), then produce the ROC table (`make wake-sweep`) and commit it
under `docs/` / BASELINES.

### Runtime bypasses (no ONNX)

| Mechanism | How |
|---|---|
| Force-wake energy | `COMSTAR_FORCE_WAKE_SCORE` on `comstar-audio` (refractory ~5s) |
| Dev inject | `POST /admin/inject` `WakeWord` with `{"score":0.99}` |
| Sleep verify | After candidate wake while sleeping, STT must look like wake/engage. Same-utterance residual (`hey comstar what's up`) runs as the turn; wake-only still opens follow-up listen. |
| Idle auto-sleep | `attention.idle_sleep_seconds` (default 600, `0` off) — silent sleep after no interaction; spoken “go to sleep” still gets a sleep-ack. |
| Working ack | `attention.working_ack_ms` (default 4500, `0` off) + `working_ack_on_tools` — spoken “working on it” only for slow **tool/query** turns (not chit-chat); final reply framed with `result_ready` if ack played. |

### M9.5 — Soak-driven retune (blocked)

Until `hey_comstar.onnx` ships, soak false-accept counts inform **force-wake**
knobs only (`COMSTAR_FORCE_WAKE_RMS`, refractory). Do not treat force-wake as the
M4 ROC gate. After ONNX train + `make wake-sweep`, retune from soak journals
(`docs/TESTING.md` §T5b).

---

## 5. Admin console + event injection

The bridge always serves **http://127.0.0.1:8781/admin/** (admin UI + APIs; Google
OAuth shares `:8781` at `/oauth/google/*`). Heal uses `GET /admin/health` (also
`/health`). From the Mac: `make admin` (needs `LocalForward 8781` in SSH config).

LAN access: set `COMSTAR_ADMIN_BIND_LAN=1` and `COMSTAR_ADMIN_TOKEN` on the bridge
unit (see `~/.config/comstar/admin.env` on the Pi), then open
`http://<pi-ip>:8781/admin/?token=<token>`. Without the token, UI/API return 401;
`/admin/health` stays open for the heal script.

When `COMSTAR_ENV=dev`, **POST /admin/inject** accepts synthetic attention events:

```json
{"event": "TranscriptReady", "text": "What time is it?"}
```

Supported events: `PersonDetected`, `PersonAbsent`, `FaceRecognized`,
`FaceUnknown`, `WakeWord`, `SpeechStart`, `SpeechEnd`, `TranscriptReady`,
`ResponseReady`, `PlaybackEnded`, `Tick`, `AttentionError`, `VisionDegraded`,
`VisionRecovered`, `EnterSleep`, `ExitSleep`.

Injected events are logged with `src: injected`. Restart / reboot / sleep /
live logs are on `/api/*` (see `docs/CONTRACTS.md` admin console).

### Road VPN (phone-home)

When the Pi is **not** on a home subnet, the bridge brings up a NetworkManager
VPN and **keeps it healthy** (probe + heal). See ADR 0011 and admin **Road VPN**.

**1. Install packages once on the Pi**

```bash
make road-vpn
# or: ssh comstar 'sudo bash /opt/comstar/src/scripts/install-road-vpn.sh'
```

Installs `network-manager-openvpn`, `network-manager-l2tp`, strongswan, and
sudoers for passwordless `nmcli`.

**2. Admin setup**

Open Road VPN panel → confirm prerequisites → paste OpenVPN and/or L2TP
credentials → **Initialize VPN** (creates NM profile, enables monitor, connects).

**3. Monitor**

With **Enable health monitor** on and off-home: periodic reconcile keeps the
tunnel up, probes `health_url` (default Ada AO `/health`), and heals (bounce /
reconnect) with backoff on failure. At home the COMSTAR VPN is torn down.

```yaml
road:
  enabled: false
  protocol: openvpn          # openvpn | l2tp | auto
  home_cidrs:
    - 192.168.89.0/24
    - 192.168.90.0/24
    - 172.16.90.0/24
  health_url: ""             # empty → orchestration base_url/health
  openvpn_connection: comstar-ovpn
  l2tp_connection: comstar-l2tp
```

Runtime + secrets: `GET/POST /admin/api/road` under
`~/.local/share/comstar/road/`.

Set `COMSTAR_ROAD_NMCLI_SUDO=0` to force plain `nmcli` (user connections only).

### Host network (Wi‑Fi + IPv4)

Admin **Network** tab (`GET/POST /admin/api/network`, ADR 0012) uses the same
`nmcli` sudoers as Road VPN. Scan/join Wi‑Fi, toggle radio, set DHCP or static
IPv4 on ethernet/wlan. Wrong static settings can lock out LAN access — keep
serial/SSH as a backup.

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

## 6b. Latency report

Bridge emits closed spans as structured logs (`evt` / `Span` helper). Standard names:

| Span | Meaning |
|---|---|
| `wake_to_listen` | wake accept → listen open |
| `stt` | utterance → transcript |
| `orchestration` | transcript → reply text |
| `tts_first` | reply → first audio |
| `tts_total` | full TTS |
| `avatar_start` | speak → avatar motion |
| `turn_total` | end-to-end turn |

```bash
# Recent spans from the Pi journal
journalctl --user -u comstar-bridge --since '1h ago' -o cat \
  | jq -c 'select(.evt=="span" or .data.name != null)' 2>/dev/null \
  | head -40

# Or grep the span name field in JSON lines
journalctl --user -u comstar-bridge --since '1h ago' | grep -E 'wake_to_listen|"stt"|orchestration|tts_first|turn_total'
```

Admin heal / health UI also surfaces recent turn timing when the console is open
(`make admin`). Target Phase 1 walk-up: spoken answer **&lt; 15s** (`turn_total`).

---

## 7. Privacy kill switch

COMSTAR is designed for local-first operation:

- **Vision:** frames go to CodeProject.AI on the LAN only; no cloud upload in Phase 1.
  COMSTAR does not write camera frames to disk.
- **Audio:** wake/VAD stay on-Pi; utterance PCM goes to the STT in use — Ada sidecars
  when Reach `speechClient` is set, else `COMSTAR_STT_URL` (often local `127.0.0.1:8090`).
  Ring buffer is in-memory only. **Optional** debug archives
  (`/tmp/comstar-last-utterance.wav`, `/opt/comstar/testdata/stt/live/`) require
  `COMSTAR_STT_ARCHIVE=1` on the STT process — default **off** (M9.7).
- **Orchestration:** AO Reach on the LAN; guest/restricted mode limits MCP tools.

### Software stop (not a guest promise)

```bash
systemctl --user stop comstar-bridge comstar-audio comstar-kiosk comstar-stt comstar-tts
```

**Disable auto-start:**

```bash
systemctl --user disable comstar-bridge comstar-audio comstar-kiosk comstar-stt comstar-tts
```

### Hardware kill (guest-facing)

Software stop is **not** sufficient as a privacy promise to a guest:

1. **Mic mute** — use the webcam/array hardware mute LED when present, or unplug the mic USB.
2. **Camera** — cover/unplug `/dev/video0` (LED off).
3. **Power** — unplug the Pi / HDMI panel for a hard stop.

**Network isolation:** unplug Ethernet / disable Wi-Fi on the Pi to confirm offline
fallback lines still play (M6 exit criterion).

Production configs must ship with `dev.bind_lan: false`. LAN WebSocket bind requires
all three gates: `COMSTAR_ENV=dev`, `comstar.dev.yaml`, and non-empty `dev.lan_token`.

---

## 7b. systemd resource limits (M9.3)

User units under `deploy/systemd/` ship with `MemoryMax` / `CPUQuota`. The bridge
uses `Type=notify` + `WatchdogSec=60` and sends `systemd-notify` heartbeats.
After deploy, confirm:

```bash
systemctl --user show comstar-bridge -p MemoryMax -p CPUQuota -p WatchdogUSec -p Type
```

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
| Admin / health | `127.0.0.1:8781` | `/admin/*` always; `/oauth/google/*` OAuth; `/admin/inject` when `COMSTAR_ENV=dev` |
| Dev inject | `127.0.0.1:8781/admin/inject` | `COMSTAR_ENV=dev` |
| STT | Ada `:8090` or local | `curl http://<stt-host>:8090/health`; bridge log `speech_reach` vs `speech_fallback` |
| TTS | Ada `:8091` or local | `curl http://<tts-host>:8091/health` (or POST `/v1/audio/speech`) |
| AO Reach | `10.0.10.16:8765` | `spike/reach_hello.dart` |
| CodeProject.AI | `10.0.10.16:32168` | `scripts/verify_cpai.sh` |

---

## 9. Common failures

| Symptom | Likely cause | Fix |
|---|---|---|
| Empty / junk STT | STT down, wrong engine, or short utterance | Check Ada speech `/health` or `systemctl --user status comstar-stt`; with `COMSTAR_STT_ARCHIVE=1`, inspect `/tmp/comstar-last-utterance.wav`; raise finalize threshold |
| Fast speech cut early | VAD silence too aggressive | Raise `COMSTAR_VAD_SILENCE_MS` (e.g. 1200); hysteresis is in `terminal/audio/vad.py` |
| Empty STT on Mac | `COMSTAR_STT_URL` unset or STT down | `make stt-dev`, export URL |
| Wake never fires | Stub model / missing ONNX | Train ONNX, or `COMSTAR_FORCE_WAKE_SCORE=0.99`, or inject `WakeWord` on `:8781/admin/inject` |
| Kiosk blank / no WS | Chromium not loading kiosk after splash | Confirm bridge `:8776` + splash `:8769`; restart `comstar-kiosk`; check `/tmp/comstar-kiosk-splash.log` |
| Desktop flashes on boot | Session chrome not installed | `scripts/install-pi-session.sh` + reboot |
| Rainbow / stock splash | Plymouth not installed | `sudo scripts/install-plymouth-comstar.sh` + reboot |
| Kiosk silent | Bridge not running or wrong `bridge=` URL | Check WS on :8777 |
| Chrome has no camera preview | Expected — kiosk has no webcam tile | Confirm bridge ffmpeg / camera LED; set `COMSTAR_CAMERA_SOURCE` |
| No greet-by-name | Face not enrolled | `enroll_face.sh` |
| AO timeout / overlay missing | AI server unreachable or cwd-relative overlay | Check `10.0.10.16:8765`; run bridge from repo root or absolute `overlay_root` |
| Google tools missing | Not paired / guest / MCP soft-skip | Say “connect my Google”; check `GOOGLE_CLIENT_*` env; tokens under `~/.local/share/comstar/google/`; preinstall `npm install --prefix ~/.local mcp-server-google-workspace@0.2.6` so bridge can use local `node dist` (nested `npx` often misses the ready window on Pi) |
| Pairing QR never shows | Kiosk outdated / `pairing.qr` dropped | Redeploy `terminal/kiosk/`; confirm bridge logs `google_pairing_start` |
| Linked but “no internet/search” | Tools MCP not registered, or ask is web search | Status: “Workspace tools …”; voice Google is Calendar/`drive.file` (not Google Search). Check bridge `mcp_overlay_ready` vs `mcp_overlay_bootstrap` |

## 9b. Full duplex + AEC (Phase 2 / ADR 0007)

Default remains `audio.duplex: half`. To enable barge-in:

1. Set `audio.duplex: full` in `comstar.yaml` (requires healthy AEC).
2. On the Pi, identify the playback **monitor** source:

```bash
pactl list short sources | grep -i monitor
# example: alsa_output.platform-….hdmi.monitor
```

3. Export on `comstar-audio`:

```bash
# ~/.config/systemd/user/comstar-audio.service.d/aec.conf
[Service]
Environment=COMSTAR_AEC=1
Environment=COMSTAR_AEC_REF_SOURCE=alsa_output.platform-….hdmi.monitor
```

4. Restart audio + bridge. Logs should show `aec_status` with `available: true`.
   If `aec_unavailable`, keep `duplex: half` — do not claim full duplex in hallway UAT.
5. Optional SpeexDSP: `pip install speexdsp` in the audio venv (`terminal/audio`).

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
2. Optional Desktop upgrade (Gmail / full Drive): create a **Web application**
   OAuth client (Desktop clients often reject custom HTTPS redirects); set
   `GOOGLE_DESKTOP_CLIENT_ID` / `GOOGLE_DESKTOP_CLIENT_SECRET`;
   set `COMSTAR_OAUTH_REDIRECT_BASE=https://comstar.mostardesigns.com` (or your
   HTTPS proxy origin) and register
   `{base}/oauth/google/callback` on that client; set `COMSTAR_OAUTH_BIND_LAN=1`
   so the proxy can reach Pi `:8781`. Configure SMTP:
   `COMSTAR_SMTP_HOST`, `COMSTAR_SMTP_PORT` (587), `COMSTAR_SMTP_USER`,
   `COMSTAR_SMTP_PASSWORD`, `COMSTAR_SMTP_FROM`. After TV pairing, COMSTAR emails
   an HTML link with the hero banner; completing it stores
   `"client":"desktop"` on the token file.
3. Export `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` on the bridge host
   (Pi: `~/.config/comstar/google.env` via systemd drop-in; Mac:
   `config/comstar.mac.env`). Never commit them.
4. As a known face, say **“connect my Google”**. Enter the spoken code on your
   phone or scan the on-screen QR.
5. Tokens land in `~/.local/share/comstar/google/<userid>.json` (`0600`).
6. Voice agent allowlist: `overlays/comstar/agent_providers/voice_responder.yaml`
   → `client.google_workspace`. Guests never get Google tools.
7. Unlink: say **“disconnect Google”**. Soft-fail if tokens are revoked — voice
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
