# COMSTAR — Hardware & Environment Baselines

Captured during bring-up on **2026-08-01 / 2026-08-02**; speech path updated
**2026-08-03** (prefer Ada speech sidecars via Reach; local STT/TTS fallback).  
Companion docs: `docs/CONTRACTS.md`, `docs/IMPLEMENTATION_PLAN.md` (M0.5), `docs/DEV_LOOP.md`, `docs/RUNBOOK.md`, `docs/adr/0003-speech-on-ada.md`.

Do **not** store passwords or tokens in this file. SSH access should use keys (see §Access).

---

## 1. Terminal board

| Field | Value |
|---|---|
| Role | COMSTAR terminal (I/O; speech compute prefers Ada; AO + vision on AI server) |
| Hostname | `comstar-ai` |
| Model | **Raspberry Pi 4 Model B Rev 1.5** |
| Revision | `c03115` |
| Serial | `10000000bf83d719` |
| Arch | `aarch64` / `arm64` |
| RAM | **4 GB** class — ~3.7 GiB usable (`MemTotal` ≈ 3882924 kB) |
| Swap | 511 MiB |
| Storage | microSD `/dev/mmcblk0p2` — **117 GB**, ~17 GB used / **94 GB free** |
| GPU/ARM split (vcgencmd) | `arm=948M`, `gpu=76M` |
| Idle temp (post-upgrade) | ~56–59 °C |
| Throttle flags | `throttled=0x0` (clean) |

**Implication for COMSTAR:** 4 GB meets the README minimum; 8 GB is recommended if the avatar renders locally. Watch M7 fps — may need `avatar.render: streamed` if WebGL cannot hold ≥24 fps.

---

## 2. Operating system & firmware (after full upgrade)

| Field | Value |
|---|---|
| Distro | Debian GNU/Linux **12 (bookworm)** — Raspberry Pi OS desktop variant |
| Kernel (running) | **`6.12.96+rpt-rpi-v8`** (`1:6.12.96-1+rpt1`, 2026-07-24) |
| Firmware (start.elf family) | May 21 2026 — `288930ab…` |
| Bootloader EEPROM | **Sun 17 May 2026** (`1779045198`) — up to date |
| VL805 (USB) firmware | `000138c0` — up to date |
| EEPROM release channel | `default` (`bootloader-2711`) |
| Desktop | **LightDM** + **labwc** (Wayland); session user `md-admin` |
| Boot UI | Plymouth theme `comstar` (optional install) → blank labwc → Chromium splash (`:8769`) → kiosk (`:8776`) |
| Wayland socket | `/run/user/1000/wayland-0` |
| Timezone | `US/Eastern`; NTP active / clock synchronized |
| User linger (systemd --user) | **`Linger=no`** — must enable before relying on user units after logout |

### Upgrade performed (2026-08-01 evening)

1. `apt-get update` + `full-upgrade` — **419 packages** upgraded, 59 new, 3 removed (~940 MB download).
2. Kernel moved **6.6.62 → 6.12.96**.
3. `rpi-eeprom-update -a` applied pending bootloader update (Jan 2023 → May 2026).
4. Rebooted; verified clean apt state (`0` upgradable).
5. Purged old `linux-image/headers` **6.6.62** packages.
6. Stayed on Bookworm (no dist-upgrade to a new major release — correct for current Raspberry Pi OS).

Post-upgrade spot checks: C525 camera + mic still enumerate; CPAI reachable; ethernet still preferred default route.

---

## 3. Access

| Field | Value |
|---|---|
| SSH user | `md-admin` |
| Ethernet IP | **`192.168.89.34/24`** (`end0`) — preferred management path |
| Wi-Fi IP | `192.168.90.102/24` (`wlan0`) — secondary |
| Groups | `sudo`, `audio`, `video`, `render`, `input`, `gpio`, `i2c`, `spi`, `netdev`, … |
| Passwordless sudo | yes (for `md-admin`) |
| Password auth | currently enabled — **replace with SSH key** for DEV_LOOP (`~/.ssh/config` Host `comstar`, `ControlMaster`, forwards 9222/8181/5678/8781) |

Suggested `/etc/hosts` (Mac + Pi) when ready:

```
192.168.89.34   comstar.lan comstar
10.0.10.16      ai-server.lan ai-server
```

---

## 4. Network

### Interfaces & routing (intentional)

| Interface | Address | NM connection | `ipv4.route-metric` | Role |
|---|---|---|---|---|
| `end0` (ethernet) | `192.168.89.34/24` | `Wired connection 1` | **100** | **Primary default gateway** → `192.168.89.1` |
| `wlan0` (Wi-Fi) | `192.168.90.102/24` | `preconfigured` | **600** | Backup default only; local `.90` access |

Changed on 2026-08-01: Wi-Fi had been metric `100` and ethernet `400`, so all internet/AI traffic preferred Wi-Fi. Metrics were flipped and persist in NetworkManager profiles.

### Observed topology

```
MacBook
  en7  192.168.89.29   ──┐
  en0  192.168.90.192  ──┼── LAN
                         │
Pi comstar-ai            │
  end0 192.168.89.34  ───┤── gateway 192.168.89.1
  wlan0 192.168.90.102 ──┘
                         │
CodeProject.AI           │
  10.0.10.16:32168  ◄────┘  (routed via .89.1 from Pi ethernet)
```

DNS on Pi: NetworkManager → `10.0.10.10`, search `mostardesigns.com`.  
`ai-server.lan` is **not** in `/etc/hosts` yet — use `10.0.10.16` or add the alias above.

Nearby on `.89` (not COMSTAR AI services): Axis / camera-style hosts at `.20`, `.30`, `.31` (HTTP).

---

## 5. Peripherals

### Display

| Field | Value |
|---|---|
| HDMI-A-1 | **connected**, mode **1024×768@60** |
| HDMI-A-2 | disconnected |
| Audio via HDMI | `vc4hdmi0` / `vc4hdmi1` ALSA cards present |
| Analog out | `bcm2835 Headphones` |

### Camera — Logitech HD Webcam C525

| Field | Value |
|---|---|
| USB ID | `046d:0826` |
| Driver | `uvcvideo` |
| Nodes | `/dev/video0` (capture), `/dev/video1` (metadata), `/dev/media4` |
| Formats | **YUYV** and **MJPG**; discrete sizes include 640×480, 960×720, 1280×720, 1280×960 |
| Verified | JPEG grab via ffmpeg from `/dev/video0` at 640×480 — works before and after OS upgrade |
| CSI / libcamera | No CSI camera; `libcamera-hello --list-cameras` → “No cameras available!” (expected) |

**COMSTAR note:** Prefer **MJPG** for the vision poll loop (lower USB bandwidth than YUYV). Do not spawn a new process per frame (M2.1).

### Microphone — C525 built-in USB audio

| Field | Value |
|---|---|
| ALSA | `card 3: C525`, device `0` → `plughw:CARD=C525,DEV=0` / `hw:3,0` |
| PipeWire source | `alsa_input.usb-046d_HD_Webcam_C525_8B309B50-00.mono-fallback` (**default source**) |
| Verified | 16 kHz mono S16_LE capture — live levels (e.g. peak ~42% FS in room test) |

**COMSTAR note:** Adequate for bring-up and close-range tests. README / M4 warn that webcam mics fail room-distance wake-word UAT; plan a ReSpeaker (or similar) if 3 m / TV-on tests fail. Do not “fix” that by dropping the wake threshold into false-accept territory.

### Playback

PipeWire default sink: built-in / mailbox stereo fallback (headphones path observed). `speaker-test` ran successfully during bring-up. Final sink choice (HDMI vs 3.5 mm vs USB speakers) still open — ties to CONTRACTS §6 audio-routing ADR in M0.6.

---

## 6. Software on the Pi

### Present (post-upgrade)

| Tool | Version / notes |
|---|---|
| Python | **3.11.2** |
| Chromium | **150.0.7871.181** (Debian/Raspberry Pi build) |
| ffmpeg | **5.1.9** (+rpt) |
| v4l2-ctl | present |
| arecord / aplay | ALSA 1.2.x |
| git, curl | present |
| PipeWire | active (Pulse compatibility socket) |
| Mesa / DRI | `/dev/dri/card0`, `card1`, `renderD128` |

### Missing (needed before M1 / DEV_LOOP)

| Tool | Why |
|---|---|
| **Dart ^3.5** | `comstar-bridge` |
| **Node.js / npm** | kiosk tooling / vite-style hot reload |
| **jq** | `make logs` pipeline |
| Audio Python stack | `sounddevice` / openWakeWord / Silero / etc. (install in venv at M4) |
| `/opt/comstar` | deploy root not created yet |
| COMSTAR systemd units | not installed yet |

### Desktop / GPU caveat

Headless Chromium GL probes failed during bring-up (common without a proper kiosk session). Real WebGL/TalkingHead fps must be measured under the labwc + HDMI kiosk path (M0.4 / M7.4).

---

## 7. AI server — CodeProject.AI + AO

Same host (`10.0.10.16`) runs multiple services:

| Service | URL | Status |
|---|---|---|
| CodeProject.AI | `http://10.0.10.16:32168` | **VERIFIED** — YOLO + Face on GPU |
| agentic-orchestration | `http://10.0.10.16:8765` | **VERIFIED** — v1.27.4, overlay+tunnel, Reach hello |
| Ollama | `http://10.0.10.16:11434` | up (`qwen2.5:14b` present) |
| STT / TTS | **Prefer Ada speech sidecars** (AO ≥ 1.28 / Reach `SpeechClient`) | Advertise `AGENTIC_SPEECH_*` on this host. Local Pi/Mac `comstar-stt`/`comstar-tts` remain fallback via `COMSTAR_*_URL`. |
| CompreFace | `http://10.0.10.16:8000` | Present (SPA); not used by COMSTAR (CPAI is vision) |

### CodeProject.AI

| Field | Value |
|---|---|
| Host | **`10.0.10.16`** |
| Port | **`32168`** |
| Product | CodeProject.AI Server |
| Version | **2.9.7** (UI assets also report 2.9.3 paths); Windows x64 package lineage `CodeProject.AI-Server-win-x64-2.9.6.zip` |
| Hostname (server) | `codeproject-ai-server` |
| Reachability | Pi (~0.4 ms via ethernet after route fix) and Mac (~0.5 ms) |
| Config URL for COMSTAR | `http://10.0.10.16:32168` |
| Detection p50 / p95 (idle, 20 samples) | **~19–20 ms / ~23–36 ms** (`docs/fixtures/cpai_detection_timing.json`, 2026-08-02) |

### agentic-orchestration

| Field | Value |
|---|---|
| Base URL | `http://10.0.10.16:8765` |
| Version | **1.27.4** |
| Hardware | NVIDIA RTX 4000 SFF Ada (~20 GB VRAM) |
| Reach probe | `spike/reach_hello.dart` → `RESULT: {ok: true, text: Hello., …}` |
| Flags | session overlay + MCP tunnel confirmed via Reach (`overlay=true tunnel=true`) |
| Live COMSTAR overlays (2026-08-02) | `client.greeter` → “Welcome, Zlatko!” (~0.85s); `client.voice_responder` → spoken confirm (~1.0s); guest greeter OK |
| Hosted MCP catalog (known ids) | `fetch_url`, `filesystem_local`, `home_assistant`, `media_audio_transcribe`, `media_understand`, `media_video_analyze` — **no** `memory` / `time` / `math` / `vision` on this host |
| STT via AO | Prefer Reach `SpeechClient` → AO-packaged HTTP sidecars (not MCP/planner). `media_audio_transcribe` MCP exists but is **not** the COMSTAR voice path. |

### Modules verified against live traffic

| Module | ID | Device | Notes |
|---|---|---|---|
| Object Detection (YOLOv8) | `ObjectDetectionYOLOv8` | **GPU** | Pi cam frame → `person` ~0.95 (+ `tv`); inference **~48–65 ms** |
| Face Processing | `FaceProcessing` | **GPU** | list + recognize both report GPU |

### API shapes observed (feeds CONTRACTS §3)

**Detection** (`POST /v1/vision/detection`) — success with `predictions[{label,confidence,x_min,y_min,x_max,y_max}]`, plus `inferenceMs`, `inferenceDevice`.

**Face list** (`POST /v1/vision/face/list`):

```json
{"success": true, "faces": [], ...}
```

No faces enrolled yet.

**Face recognize miss** (unregistered face in frame) — **answers the open CONTRACTS question:**

```json
{
  "success": true,
  "message": "No known faces",
  "count": 1,
  "predictions": [
    {"confidence": 0, "userid": "unknown", "x_min": …, "y_min": …, "x_max": …, "y_max": …}
  ],
  "inferenceDevice": "GPU",
  …
}
```

So a miss is **`userid: "unknown"`** (with a box), not an empty `predictions` array. Still handle empty arrays defensively.

### Not verified on this host yet

- GPU contention under house-camera load (M0.2)
- Face enrollment end-to-end under oblique angles / low light

---

## 8. Mac developer machine (context)

Observed during the same bring-up:

| Field | Value |
|---|---|
| Ethernet | `192.168.89.29` (`en7`) — default route via `192.168.89.1` |
| Wi-Fi | `192.168.90.192` (`en0`) |
| Role | Cursor / editor; intended host for Loop B bridge-dev and kiosk-dev |

---

## 9. Session changelog (what we did)

Ordered summary of operator actions during this bring-up:

1. Saved project docs: `README.md`, hero `docs/comstar-banner.png`, `docs/CONTRACTS.md`, `docs/IMPLEMENTATION_PLAN.md`, `docs/DEV_LOOP.md`.
2. Interrogated Pi at `md-admin@192.168.89.34` for COMSTAR readiness.
3. Confirmed **Logitech C525** video + mic after USB attach (capture tests passed).
4. Located and verified **CodeProject.AI** at **`10.0.10.16:32168`** (YOLOv8 + Face on GPU; miss shape documented).
5. Set **ethernet as preferred default gateway** (NM metrics 100 / 600).
6. Full **OS + firmware upgrade** (apt full-upgrade, EEPROM, reboot onto 6.12.96, purge old kernels).
7. Wrote this baseline document.

---

## 10. Readiness vs COMSTAR plan

| Area | Status |
|---|---|
| Pi 4 + Bookworm 64-bit + desktop/kiosk path | Ready |
| Camera (UVC) | Ready (C525 / `/dev/video0`) |
| Mic capture | Ready (C525); room-distance UAT open |
| HDMI panel | Ready |
| Ethernet preferred routing | Ready |
| CodeProject.AI vision | Ready at `10.0.10.16:32168` |
| Dart / Node / jq / deploy root | Ready (`/opt/comstar/src`) |
| systemd linger + units | Ready (bridge, audio, kiosk, stt, tts) |
| AO Reach | Ready (`10.0.10.16:8765`) |
| Speech (Ada sidecars + Pi/Mac fallback) | Prefer Reach when advertised; local `:8090`/`:8091` for bring-up |
| Audio routing ADR (kiosk sink) | Accepted (ADR 0001) |
| TalkingHead on-device fps | **Not measured** (GLB open) |
| Face enrollment | `zlatko` enrolled; walk-up UAT open |

**Can develop on Mac and test on Pi:** yes — `docs/DEV_LOOP.md` (Loops A–D). Mac-only browser voice: Loop B+.

---

## 11. Recommended next bootstrap (not done yet)

1. SSH key + `~/.ssh/config` Host `comstar` (no password in scripts).  
2. `sudo loginctl enable-linger md-admin`.  
3. Install Dart ^3.5, Node/npm, jq.  
4. Add `ai-server.lan` → `10.0.10.16` on Mac and Pi.  
5. Run M0 probe script `scripts/verify_cpai.sh` and commit fixtures under `docs/fixtures/`.  
6. Close audio-routing ADR; measure Chromium WebGL on the HDMI panel.

---

*Last updated: 2026-08-02 (post OS/firmware upgrade and CPAI/camera verification).*

## 12. Kokoro TTS on Ada (TTS.0) — 20260807T155500Z

Captured by `scripts/verify_tts.sh` → `docs/fixtures/kokoro_bench_20260807T155500Z.json`.

| Field | Value |
|---|---|
| Host | `10.0.10.16` (RTX 4000 Ada) |
| Model dir | `/home/zlatko.lakisic/agentic-speech-models/tts-kokoro` |
| sherpa-onnx | 1.13.4 |
| Provider requested | `cpu` |
| Provider effective | `cpu` |
| Speaker id | 0 (af_heart if 0) |
| Sample rate | 24000 Hz |

### Metrics (raw)

| mode | n | RTF mean | RTF p50 | TTFC ms mean | TTFC ms p50 | TTFC ms min | synth_sec mean | multi-callback? |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| idle | 6 | 1.078 | 1.0658 | 1516.46 | 1464.32 | 1105.62 | 1.5165 | no |
| contended | 6 | 0.9634 | 0.9555 | 1333.45 | 1336.2 | 1082.15 | 1.3335 | no |

### TTS.0.2 streaming (from installed API + empirical)

API (sherpa-onnx 1.13.4 Python binding): OfflineTts.generate(text, sid, speed, callback=None) documents an optional callback(samples, progress)->int invoked during speech generation with sample chunks (C header: SherpaOnnxGeneratedAudioCallback — incremental). Same OfflineTts path serves Kokoro via OfflineTtsKokoroModelConfig. EMPIRICAL (kokoro-en-v0_19 on this host): callback fires exactly once per utterance with the full sample buffer; TTFC ≈ full synth_sec. So Kokoro is buffer-complete for first-audio purposes unless sentence-level chunking is added in tts_server.py. max_num_sentences!=1 is ignored for Kokoro.

- `generate_doc_mentions_callback`: True
- `OfflineTts` methods: `generate`, `num_speakers`, `sample_rate`

*Do not treat these numbers as product SLOs until TTS.0.3 voice pick and TTS.0.4 sample-rate decision land in ADR 0008.*

**Note:** Ada `venv-tts` sherpa-onnx ORT has **no CUDA EP** (`Please compile with -DSHERPA_ONNX_ENABLE_GPU=ON`); `provider=cuda` falls back to CPU. Contended mode storms CPAI detection; Kokoro itself stayed on CPU so VRAM (~15.7 GiB) is CPAI/other, not TTS.

## 13. Quiet hours / wake-state (M10.0.2) — 2026-08-07

Captured on Pi `comstar` mid-afternoon + journal lookback. `screen_state` terminal
MCP tool is **not implemented**; reality below is OS + COMSTAR attention sleep.

| Check | Result |
|---|---|
| Units | `comstar-bridge` / `kiosk` / `audio` **active** |
| Panel | `wlr-randr`: HDMI-A-1 **Enabled: yes**, 1024×600 @ 60Hz, transform 90° |
| Chromium kiosk | Running (kiosk URL on `:8776`) |
| Admin health | `sleeping: false` at sample; sink path live |
| Default sink | `comstar_hdmi`, **Mute: no**, volume **100%** |
| paplay probe | `/tmp/comstar-soak-beep.wav` → `paplay --device=comstar_hdmi` → **ok** |
| Attention sleep | Frequent `sleep_enter` in journal (idle / spoken sleep). `TerminalControl.sleepEnter` sets a flag only — **does not mute** the sink |
| Overnight DPMS | No separate DPMS blanking observed in labwc config; overnight “asleep” ≈ attention `Sleeping`, panel typically still driven |

### Implication for M10.3

- An announcement while attention-sleeping is **not** automatically silent: TTS +
  paplay still work unless the user muted the sink.
- Prefer **ExitSleep / kiosk phase wake** before urgent speak for UX (eyes on
  avatar), but do not block delivery solely on `sleeping==true`.
- If sink is muted, gate must defer or use M11 channel — log, never silent-drop
  urgent.

See ADR 0009 delivery policy table.

