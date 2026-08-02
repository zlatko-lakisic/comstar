<p align="center">
  <img src="docs/comstar-banner.png" alt="COMSTAR AI" width="520">
</p>

<h1 align="center">COMSTAR AI</h1>

<p align="center">
  <em>An always-on, embodied AI presence for your home.<br>
  It sees you, knows you, listens for you, and answers with a face.</em>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-pre--alpha-orange" alt="status">
  <img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="license">
  <img src="https://img.shields.io/badge/platform-Raspberry%20Pi%204-c51a4a" alt="platform">
  <img src="https://img.shields.io/badge/backend-agentic--orchestration-6f42c1" alt="backend">
</p>

---

## Table of contents

- [What COMSTAR is](#what-comstar-is)
- [Why it exists](#why-it-exists)
- [Architecture](#architecture)
- [The attention model](#the-attention-model)
- [Hardware](#hardware)
- [Software stack](#software-stack)
- [Repository layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Configuration](#configuration)
- [Enrolling a face](#enrolling-a-face)
- [Training the wake word](#training-the-wake-word)
- [MCP topology](#mcp-topology)
- [Latency budget](#latency-budget)
- [Privacy model](#privacy-model)
- [Roadmap](#roadmap)
- [Design decisions](#design-decisions)
- [Troubleshooting](#troubleshooting)
- [Credits and licensing](#credits-and-licensing)

---

## What COMSTAR is

COMSTAR is a physical AI terminal. A small screen on a Raspberry Pi, a camera, a microphone, and a speaker. It runs continuously. When you walk into frame it recognises you, greets you by name, and waits. You ask it something. A 3D avatar answers you out loud.

Behind that is [`agentic-orchestration`](https://github.com/zlatko-lakisic/agentic-orchestration) — a CrewAI-based, model-agnostic orchestration engine with dynamic planning, per-task MCP integration, a SQLite knowledge base, session memory, and a learning loop. COMSTAR is a face for that engine, not a wrapper around a chatbot.

The client talks to the engine through [`agentic-orchestration-reach`](https://github.com/zlatko-lakisic/agentic-orchestration-reach) (AO Reach), which gives it ephemeral per-session agents and a WebSocket reverse tunnel for exposing local tools to the orchestrator.

Everything runs on your own hardware. No cloud dependency, no API keys required, no vendor lock-in.

---

## Why it exists

Proto Hologram proved the thesis: an embodied presence in a room is categorically different from a video call or a text box. People walk up to it. People talk to it without being prompted. But Proto is $10k–$250k of proprietary hardware running a closed OS, and you cannot put your own agent logic behind it.

COMSTAR is the open version. Commodity parts, a GPU you already own, and an orchestration engine you can rewrite.

**Design principles:**

| | |
|---|---|
| **Local by default** | Nothing leaves the LAN unless you explicitly wire it to. |
| **Thin client, fat brain** | The Pi does I/O. All inference happens on the AI server. |
| **Identity is the session** | Face recognition isn't decoration — it selects the AO session and its memory. |
| **The room is a tool** | Presence and vision are MCP tools the planner can call, not context you prepend. |
| **Latency is a feature** | If a response takes longer than ~15s, the interaction is broken. Budget accordingly. |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│  TERMINAL — Raspberry Pi 4                                              │
│                                                                         │
│   USB camera ──► frame grabber ──► JPEG @ 1-5 fps ──────────┐           │
│                                                             │           │
│   Microphone ──► openWakeWord ──► Silero VAD ──► PCM ───────┤           │
│                  (local, always on)                         │           │
│                                                             │           │
│   HDMI screen ◄── Chromium kiosk ◄── TalkingHead.js         │           │
│   Speakers    ◄── audio out       ◄── Piper TTS             │           │
│                          ▲                                  │           │
│                          │                                  │           │
│                  ┌───────┴──────────────────────────────────┴───────┐   │
│                  │  ao_reach sidecar (Dart)                         │   │
│                  │   SessionBridge · LocalMcpHost · OverlayPacker   │   │
│                  │   local WS API on 127.0.0.1 for the kiosk        │   │
│                  └───────┬──────────────────────────────────────────┘   │
└──────────────────────────┼──────────────────────────────────────────────┘
                           │  LAN
                           │  ├─ WSS  ── AO session overlay + reverse tunnel
                           │  ├─ HTTP ── CodeProject.AI  :32168
                           │  └─ HTTP ── STT / TTS
                           ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  AI SERVER — NVIDIA RTX A4000                                           │
│                                                                         │
│   ┌──────────────────────────┐   ┌──────────────────────────────────┐   │
│   │  agentic-orchestration   │   │  CodeProject.AI Server  :32168   │   │
│   │   daemon ≥ v1.27.0       │   │   • Object Detection (YOLO)      │   │
│   │   • dynamic planner      │◄──┤   • Face Processing              │   │
│   │   • CrewAI agents        │   │   (already serving house cams)   │   │
│   │   • MCP registry         │   └──────────────────────────────────┘   │
│   │   • SQLite KB + FTS      │                                          │
│   │   • session memory       │   ┌──────────────────────────────────┐   │
│   │   • learning / eval loop │   │  faster-whisper (STT, CUDA)      │   │
│   └──────────────────────────┘   └──────────────────────────────────┘   │
│                                                                         │
│   AGENTIC_SERVE_SESSION_OVERLAY=1                                       │
│   AGENTIC_SERVE_MCP_TUNNEL=1                                            │
└─────────────────────────────────────────────────────────────────────────┘
```

**The split, stated plainly:** the Pi captures and presents. The server thinks. The only inference running on the Pi is the wake word model and the voice activity detector, because those must stay local for the privacy model to hold.

---

## The attention model

"Always on" is not a boolean. COMSTAR climbs a ladder of attention states, each with a different cost and a different tolerance for false positives.

| State | Trigger in | What's running | What's captured |
|---|---|---|---|
| **Ambient** | idle | wake word model, low-rate presence polling | nothing persisted |
| **Noticed** | YOLO `person` class in frame | presence tracking | nothing persisted |
| **Engaged** | face match returns a known `userid` | AO session opened under that identity | greeting emitted |
| **Listening** | wake word · follow-up window · face-attention | VAD, audio streaming to STT | utterance only |
| **Responding** | end of speech, ~700ms silence | orchestration → TTS → avatar | response + transcript to session |

**Transitions worth understanding:**

- **Ambient → Noticed** fires on the YOLO `person` class, never on motion. Motion triggers on curtains and pets.
- **Noticed → Engaged** is the moment that carries the whole product. You walked into frame and it addressed you by name without being summoned.
- **Engaged → Listening** has three doors. The wake word `hey comstar` (four syllables, which buys a much lower false-accept rate than a two-syllable word). A **follow-up window** of 8–10 seconds after any response, during which no wake word is needed. And optionally **face-attention** — a matched face looking at the screen while speaking counts as being addressed. That third door is behind a feature flag, because it is the difference between magic and an assistant that answers your phone calls.
- **Responding → Ambient** decays after the follow-up window closes and the person leaves frame.

Identity is cached with a TTL bound to continuous presence. Face recognition runs on transition, not per frame.

---

## Hardware

| Component | Part | Notes |
|---|---|---|
| Terminal | Raspberry Pi 4 (4GB+) | 8GB recommended if rendering the avatar locally |
| Camera | Logitech USB webcam | Any UVC camera; used for vision only |
| Microphone | **ReSpeaker 2-Mic / 4-Mic array** or USB conference puck | *Strongly recommended over the webcam's built-in mic* — see below |
| Display | Small HDMI panel | 800×480 to 1280×720 |
| Audio out | USB or 3.5mm powered speakers | |
| Brain | AI server with NVIDIA RTX A4000 | Runs AO, CodeProject.AI, and STT |
| Network | Wired ethernet to the Pi | Wi-Fi adds jitter to the frame stream |

> **On the microphone.** The webcam's built-in mic is the weakest link in the entire build. Those capsules are tuned for a face 40cm away. At 2–3m across a room with any reverb, wake-word accuracy falls off a cliff. A beamforming array will do more for the felt quality of this project than any other single upgrade. Keep the webcam for vision, add a separate mic for audio.

---

## Software stack

| Layer | Choice | Rationale |
|---|---|---|
| Client SDK | `ao_reach` (Dart ^3.5) | Session overlays + reverse MCP tunnel, native to AO |
| Client shell | Dart sidecar daemon + Chromium kiosk | Sidecar speaks REACH; kiosk renders the avatar; they talk over local WS |
| Avatar | [TalkingHead.js](https://github.com/met4citizen/TalkingHead) (Three.js / WebGL) | Real-time IPA-mapped viseme lip-sync, GLB avatars |
| Avatar model | Ready Player Me / Microsoft RocketBox | Free, GLB, pre-rigged for blend shapes |
| Animations | [Mixamo](https://www.mixamo.com) | 2,000+ royalty-free mocap clips |
| Vision | **CodeProject.AI Server** (`:32168`) | Already deployed, CUDA-backed, serving house cameras |
| Wake word | [openWakeWord](https://github.com/dscripka/openWakeWord) | Free, local, custom words trainable from synthetic audio |
| VAD | Silero VAD | Lightweight end-of-speech detection |
| STT | faster-whisper (CUDA) | ~200–400ms for a short utterance on the A4000 |
| TTS | Piper (local) with optional cloud fallback | Roughly realtime on the Pi, no network hop |
| Orchestration | [`agentic-orchestration`](https://github.com/zlatko-lakisic/agentic-orchestration) ≥ v1.27.0 | Planner, agents, MCP, KB, learning loop |

---

## Repository layout

```
comstar/
├── docs/
│   ├── comstar-banner.png
│   ├── architecture.md
│   └── adr/                     # architecture decision records
├── terminal/                    # everything that runs on the Pi
│   ├── bridge/                  # Dart — ao_reach sidecar
│   │   ├── bin/comstar_bridge.dart
│   │   ├── lib/
│   │   │   ├── session.dart     # SessionBridge lifecycle + identity headers
│   │   │   ├── attention.dart   # the state machine
│   │   │   ├── vision.dart      # CodeProject.AI client
│   │   │   └── local_ws.dart    # 127.0.0.1 API for the kiosk
│   │   └── pubspec.yaml
│   ├── audio/                   # Python — wake word, VAD, capture, playback
│   │   ├── wakeword.py
│   │   ├── vad.py
│   │   └── playback.py
│   └── kiosk/                   # web — avatar renderer
│       ├── index.html
│       ├── avatar.js            # TalkingHead wiring
│       └── assets/*.glb
├── overlays/                    # AO session overlay definitions
│   └── comstar/
│       └── agent_providers/
│           ├── voice_responder.yaml
│           └── greeter.yaml
├── mcp/                         # MCP shims
│   ├── vision_mcp/              # wraps CodeProject.AI for the orchestrator
│   └── terminal_mcp/            # Pi-local: display, speaker, mic state
├── config/
│   └── comstar.example.yaml
└── scripts/
    ├── enroll_face.sh
    └── train_wakeword.py
```

---

## Prerequisites

**On the AI server:**

- `agentic-orchestration` daemon **≥ v1.27.0** with:
  ```bash
  export AGENTIC_SERVE_SESSION_OVERLAY=1
  export AGENTIC_SERVE_MCP_TUNNEL=1
  ```
- CodeProject.AI Server reachable on `:32168`, with both the **Object Detection** and **Face Processing** modules installed and confirmed running on CUDA. Check the dashboard at `http://<server>:32168` — the Face module is more prone than Object Detection to silently falling back to CPU.
- faster-whisper exposed over HTTP (or run via your existing inference host).

**On the Pi:**

- Raspberry Pi OS 64-bit (Bookworm or later)
- Dart SDK ^3.5
- Python 3.11+
- Node.js (only if using `LocalMcpHost` to spawn stdio MCPs via `npx`)
- Chromium

---

## Installation

```bash
git clone https://github.com/zlatko-lakisic/comstar.git
cd comstar
```

**1 — Bridge (Pi)**

```bash
cd terminal/bridge
dart pub get
dart compile exe bin/comstar_bridge.dart -o /usr/local/bin/comstar-bridge
```

**2 — Audio (Pi)**

```bash
cd terminal/audio
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

**3 — Kiosk (Pi)**

```bash
cd terminal/kiosk
npm install
```

**4 — Register the overlay**

The bridge registers `client.*` agents with the AO daemon at session start, from `overlays/comstar/agent_providers/*.yaml`. These are ephemeral — they exist for the life of the session and are not mounted on the host.

**5 — Run**

```bash
systemctl --user enable --now comstar-bridge
systemctl --user enable --now comstar-audio
systemctl --user enable --now comstar-kiosk
```

---

## Configuration

`config/comstar.yaml`:

```yaml
orchestration:
  base_url: https://ao.lan
  ttl_seconds: 3600
  timeout_seconds: 15
  overlay_root: ./overlays/comstar

vision:
  codeproject_url: http://ai-server.lan:32168
  detection_endpoint: /v1/vision/detection
  recognize_endpoint: /v1/vision/face/recognize
  ambient_fps: 1              # polling rate while idle
  engaged_fps: 3              # polling rate while a person is present
  person_confidence: 0.60
  face_confidence: 0.55
  recognize_votes: 3          # consensus frames before accepting an identity
  identity_ttl_seconds: 300

audio:
  wakeword_model: ./models/hey_comstar.onnx
  wakeword_threshold: 0.55
  vad_silence_ms: 700
  max_utterance_seconds: 15
  followup_window_seconds: 10
  duplex: half                # half | full  (full requires AEC)

avatar:
  render: local               # local | streamed
  model: ./assets/comstar.glb
  tts: piper
  piper_voice: en_US-ryan-high

attention:
  face_attention_trigger: false   # experimental — see notes
  stranger_mode: restricted       # restricted | greet | ignore
```

---

## Enrolling a face

Enrollment is a single HTTP call to CodeProject.AI. There is no UI to build — the `userid` you register here becomes the AO session identity.

```bash
curl -X POST "http://ai-server.lan:32168/v1/vision/face/register" \
  -F "userid=zlatko" \
  -F "image1=@enroll/01.jpg" \
  -F "image2=@enroll/02.jpg" \
  -F "image3=@enroll/03.jpg"
```

Verify:

```bash
curl -X POST "http://ai-server.lan:32168/v1/vision/face/list"

curl -X POST "http://ai-server.lan:32168/v1/vision/face/recognize" \
  -F "image=@test.jpg" -F "min_confidence=0.5"
# → {"predictions":[{"userid":"zlatko","confidence":0.87, ...}]}
```

> **Enroll from the terminal itself.** Capture the enrollment frames using the actual Logitech camera, at the actual distance, under the actual lighting where COMSTAR will live. Enrollment-condition mismatch is the single largest cause of flaky recognition. Good studio photos will make it *worse*, not better.

The Face Processing module uses DeepStack-derived embeddings, which are older than ArcFace/InsightFace. For a household of a few people at 1–2m facing the camera this is entirely adequate; it degrades faster at oblique angles and in low light. Ten to twenty enrollment frames across a few sessions beats three perfect ones.

**Identity → session mapping.** The `userid` returned by `face/recognize` is passed straight through as the AO connection header:

```dart
ReachConnectionConfig(
  baseUrl: config.orchestration.baseUrl,
  headers: {
    'x-agentic-user-name': recognisedUserId,        // from CodeProject.AI
    'x-agentic-session-id': 'comstar-$recognisedUserId',
    'x-warpgate-token': token,
  },
  ttlSeconds: 3600,
)
```

Session memory and KB scoping are therefore per-person for free. An unrecognised face opens an anonymous session with a restricted overlay.

---

## Training the wake word

`hey comstar` is not in any pretrained set, so you train it. openWakeWord supports fully synthetic training — no recording sessions required.

```bash
python scripts/train_wakeword.py \
  --phrase "hey comstar" \
  --tts piper \
  --n-samples 20000 \
  --out terminal/audio/models/hey_comstar.onnx
```

Generate positives with Piper across multiple voices, speaking rates, and pitches; mix in room impulse responses and negative samples from ambient household audio. Tune `wakeword_threshold` against a recording of a normal evening in the room — you want zero false accepts over an hour before you worry about the miss rate.

---

## MCP topology

The reverse tunnel exists for tools that are *only reachable from the Pi*. Everything co-located with the daemon registers as a plain hosted HTTP MCP. Getting this split right matters — routing server-side services through the tunnel adds a hop for nothing.

**Hosted (server-side, direct):**

| MCP | Exposes |
|---|---|
| `vision` | `who_is_present`, `describe_view`, `check_camera` — wraps CodeProject.AI |
| `memory` | KB / session recall, SQLite FTS |
| `home_assistant` | Local device control |
| `time`, `math` | Trivial, fast |

**Tunnelled (Pi-local, over `tunnel://session-mcp/…`):**

| MCP | Exposes |
|---|---|
| `terminal` | `set_display`, `play_tone`, `mic_status`, `screen_state` |
| `filesystem_local` | Scoped local paths, if needed |

**Excluded from voice sessions** — too slow for the 15s budget. Web search, arxiv, and any long-running task belong in batch flows (a morning briefing), not in a conversation.

The payoff of putting vision behind an MCP rather than prepending it to the prompt: the planner can *decide to look*. "Is anyone else in the room?" becomes a tool call the orchestrator issues mid-plan, rather than context you guessed it would need.

---

## Latency budget

Total target: **under 15 seconds**, ideally under 6.

| Stage | Budget | Notes |
|---|---|---|
| Wake word → capture start | ~50ms | local, negligible |
| Utterance + VAD close | speech + 700ms | user-controlled |
| STT (faster-whisper, CUDA) | 200–400ms | stream audio progressively so this overlaps capture |
| Orchestration | 2–10s | dominated by MCP calls; this is where the budget goes |
| TTS (Piper, Pi) | ~1s | roughly realtime; first chunk can start earlier |
| Avatar render + playback | ~200ms | |

Orchestration is the only variable that matters. Everything else is noise. If you're over budget, the fix is MCP selection, not codec tuning.

---

## Privacy model

This device has a camera and a microphone pointed at your home. The boundaries are deliberate:

1. **The wake word runs on the Pi.** Audio is held in a rolling in-memory buffer and never persisted. Nothing is transmitted anywhere until the wake word fires or a session is explicitly active.
2. **No inference leaves the LAN.** STT, vision, TTS, and orchestration all run on hardware you own.
3. **Camera frames are transient.** Sent to CodeProject.AI for inference, not written to disk by COMSTAR.
4. **Face descriptors live in CodeProject.AI**, on your server, under `userid`s you chose.
5. **Transcripts are session-scoped** and retained under AO's session memory policy — configure retention there.
6. **There is a hardware kill.** Wire a physical switch or use the mic array's mute. Software mute is not a promise you can make to a guest.

Be deliberate about this now, both because it's the right default and because it's the answer you'll want ready the first time someone in your house asks what the camera is doing.

---

## Roadmap

**Phase 1 — First contact** *(current)*
- [ ] Pi capture loop → CodeProject.AI detection + recognition
- [ ] `ao_reach` sidecar with identity-mapped sessions
- [ ] Attention state machine (Ambient → Noticed → Engaged)
- [ ] openWakeWord `hey comstar` model trained and tuned
- [ ] STT → orchestration → TTS round trip
- [ ] TalkingHead avatar rendering with lip-sync
- [ ] **Success criterion:** walk up, get greeted by name, ask a question, get a spoken answer in under 15s

**Phase 2 — Presence**
- [ ] Custom COMSTAR avatar (rigged for the chosen render path)
- [ ] Sentiment → gesture and expression mapping
- [ ] Full-duplex barge-in with AEC
- [ ] Multi-user greetings and per-person context
- [ ] House-wide presence via existing camera events (MQTT / Home Assistant)

**Phase 3 — Distribution**
- [ ] Additional Pi terminals in other rooms
- [ ] Session handoff between terminals as you move
- [ ] Shared KB across all endpoints

**Phase 4 — Integration**
- [ ] Home automation actions
- [ ] Morning briefing (calendar, weather, news — batch, not conversational)
- [ ] Email and Slack triage
- [ ] Repo and CI monitoring

---

## Design decisions

| # | Decision | Chosen | Rejected | Why |
|---|---|---|---|---|
| 1 | Vision engine | CodeProject.AI Server | face-api.js, MediaPipe, custom InsightFace | Already deployed, GPU-backed, co-located with AO. Enrollment is a curl call. Deletes an entire subsystem. |
| 2 | Transport to AO | AO Reach (WS + overlays + tunnel) | Plain REST `/voice/query` | Overlays give per-session agents; the tunnel lets the planner call Pi-local tools. REST can't express either. |
| 3 | Client shell | Dart sidecar + Chromium kiosk | Pure Flutter, pure Electron | REACH is Dart; TalkingHead is browser JS. The sidecar keeps both native rather than forcing one into the other. |
| 4 | Where inference runs | AI server | On-Pi (Coral TPU, NCNN) | YOLO + face + STT + avatar does not fit on four Cortex-A72 cores. The A4000 is already there and idle. |
| 5 | Wake word | openWakeWord | Porcupine, Precise | Free, local, custom phrases trainable from synthetic audio, no per-keyword licence. |
| 6 | Duplex mode | Half (Phase 1) | Full duplex with AEC | Shared enclosure means acoustic echo; AEC on a USB mic with no reference channel is genuinely hard. Ship half, revisit. |
| 7 | Identity source | Face → `x-agentic-user-name` | Prompt-prefixed context | Makes recognition load-bearing rather than cosmetic. Session memory scopes per person automatically. |
| 8 | Voice MCP set | Fast MCPs only | All MCPs | Web search and arxiv blow the 15s budget. Batch those elsewhere. |

Longer-form records live in `docs/adr/`.

---

## Troubleshooting

**Recognition is inconsistent.** Almost always enrollment-condition mismatch. Re-enroll from the terminal camera under normal room lighting, across several sessions and head angles. Raise `recognize_votes` before you lower `face_confidence`.

**Inference latency climbs under load.** CodeProject.AI runs a queue per module. If house cameras are already firing detections on motion, COMSTAR is competing for the same GPU slot. Watch queue times on the dashboard with everything running, then drop `ambient_fps` to 1.

**Face module is slow but Object Detection is fast.** Confirm the Face module actually picked up CUDA in the dashboard. It falls back to CPU more readily than Object Detection does.

**Wake word fires at the TV.** Retrain with the TV audio as negatives, and raise the threshold. Four-syllable phrases have a lot of headroom here — use it.

**Wake word misses across the room.** This is the microphone, not the model. See the hardware note.

**Avatar stutters on the Pi.** Drop the render resolution, or switch `avatar.render` to `streamed` and render headless on the A4000 — the Pi 4 decodes H.264 in hardware and LAN latency is 50–100ms.

**Lip-sync drifts.** Viseme quality depends on the TTS. Piper's timing is adequate; if you need better, the cloud engines expose richer viseme streams.

---

## Credits and licensing

Built on:

- [`agentic-orchestration`](https://github.com/zlatko-lakisic/agentic-orchestration) — Apache-2.0
- [`agentic-orchestration-reach`](https://github.com/zlatko-lakisic/agentic-orchestration-reach) — Apache-2.0
- [CodeProject.AI Server](https://github.com/codeproject/CodeProject.AI-Server)
- [TalkingHead](https://github.com/met4citizen/TalkingHead) — met4citizen
- [openWakeWord](https://github.com/dscripka/openWakeWord) — dscripka
- [Piper](https://github.com/rhasspy/piper) — Rhasspy
- [faster-whisper](https://github.com/SYSTRAN/faster-whisper)
- Ready Player Me · Microsoft RocketBox · Mixamo

Conceptually indebted to Proto Hologram for proving that embodied presence beats a screen — and to the fact that nobody had built an open version.

**Licence:** Apache-2.0.

**Trademark note:** "ComStar" and the ComStar starburst are BattleTech intellectual property (Topps / Catalyst Game Labs). This is a personal, non-commercial project and the name and mark are used affectionately, not commercially. Any commercial release would require a rebrand.

---

<p align="center">
  <sub>Not a mystical AI. A tool you engineered — transparent, hackable, fast.</sub>
</p>
