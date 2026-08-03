# COMSTAR — Implementation Tracker

**Purpose:** single place to track Phase 1 progress.  
**Sources of truth for *what* to build:** `docs/IMPLEMENTATION_PLAN.md`, `docs/CONTRACTS.md`, `docs/DEV_LOOP.md`.  
**Environment facts:** `docs/BASELINES.md`.

**Rules**
- Do not start M(n+1) until every M(n) exit criterion below is checked.
- When an exit criterion is met, check it here **and** note the date.
- If CONTRACTS change, update CONTRACTS first, then code, then this tracker.
- Effort numbers are ideal hours from the plan (~112 h total Phase 1).

**Status legend:** `not_started` · `in_progress` · `blocked` · `done`

---

## Current position

| Field | Value |
|---|---|
| Active milestone | **M4 / M7 / M8 hardware gates** (software path largely wired) |
| Overall Phase 1 | ~75% |
| Last updated | 2026-08-03 |
| Board | `comstar-ai` Pi 4B 4GB @ `192.168.89.34` — SSH Host `comstar` (key auth) |
| Vision backend | CodeProject.AI `10.0.10.16:32168` (GPU YOLO + Face) — `verify_cpai.sh` green |
| AO Reach | `10.0.10.16:8765` v1.27.4 — greeter + voice_responder live PASS |
| Speech | On-Pi `comstar-stt` (faster-whisper tiny) + `comstar-tts` (Piper/sherpa) |
| Product code | bridge + audio + kiosk + STT/TTS under `/opt/comstar/src` systemd user units |
| Packaging | `deploy/deploy.sh` creates config, installs units, waits for `:8778` |
| Tests | Dart + Python unit tests green on Mac; live STT gate needs more bridge fixtures |

### Remaining before Phase 1 exit

- Wake-word ONNX train + ROC (M4) — bypasses ready (`wake.force`, inject, `COMSTAR_FORCE_WAKE_SCORE`)
- TalkingHead GLB lip-sync (M7) — HTMLAudio path VERIFIED; GLB still SPEC
- Face enrollment with a person in frame (M8)
- 24 h soak + failure matrix (M9)

### Open blockers / gaps

| ID | Item | Blocks | Owner note |
|---|---|---|---|
| B6 | No faces enrolled | M8 greet-by-name | Camera clear but empty room → `ENROLL_SKIPPED_NO_FACE` |
| B8 | Wake ONNX not trained | M4 ROC exit | Runtime + refractory done; train script documents bypasses |
| B9 | TalkingHead GLB missing | M7 lip-sync UAT | Audio path + state visuals shipping |
| B11 | Live STT fixture set thin | M6 voice UAT gate | Need ≥10 labeled `source=bridge` captures; parecord goldens do not count |
---

## Milestone rollup

| # | Name | Effort | Status | Progress | Gate |
|---|---|---|---|---|---|
| M0 | Ground truth | 6h | `done` | 100% | CPAI+AO+baselines+ADR |
| M1 | Skeleton & config | 8h (+3h DEV_LOOP) | `done` | 100% | three processes + deploy |
| M2 | Vision client | 10h | `done` | 100% | offline tests + live CPAI |
| M3 | Attention state machine | 12h (+4h console) | `done` | 100% | property + branch tests |
| M4 | Audio pipeline | 14h | `in_progress` | ~70% | wake ROC + hardware UAT |
| M5 | AO Reach session | 12h | `in_progress` | ~80% | greeter/voice live; MCP tunnel partial |
| M6 | Voice round trip | 10h | `in_progress` | ~85% | On-Pi whisper STT + sherpa TTS; live fixture UAT open |
| M7 | Avatar & kiosk | 14h | `in_progress` | ~50% | audio path + ADR; GLB open |
| M8 | First contact | 10h | `in_progress` | ~40% | wiring done; enroll/walk-up open |
| M9 | Hardening & soak | 16h | `not_started` | 0% | 24h soak + runbook polish |

---

## Preflight

- [x] Pi identified and documented (`docs/BASELINES.md`)
- [x] OS fully upgraded
- [x] Ethernet preferred default route
- [x] USB camera + mic + HDMI
- [x] CodeProject.AI GPU modules
- [x] Face-miss shape (`userid: "unknown"`)
- [x] SSH key + `~/.ssh/config` Host `comstar`
- [ ] `ai-server.lan` → `10.0.10.16` on Mac and Pi (optional; IP used everywhere)
- [x] Dart / Node / jq on Pi
- [x] linger enabled
- [x] AO overlay + tunnel
- [x] STT via on-Pi `scripts/stt_server_whisper.py` (`comstar-stt` :8090) — fallback
- [x] TTS via on-Pi `scripts/tts_server.py` (`comstar-tts` :8091) — fallback
- [x] Prefer Reach `SpeechClient` (AO ≥ 1.28 / Reach ≥ 0.2); env URL fallback

---

## M0 — Ground truth — `done`

| ID | Task | Status |
|---|---|---|
| M0.1 | `scripts/verify_cpai.sh` + fixtures | `done` |
| M0.2 | GPU baselines (idle p50/p95) | `done` (loaded contention optional) |
| M0.3 | `spike/reach_hello.dart` | `done` |
| M0.4 | TalkingHead / avatar API → CONTRACTS §9 | `done` (audio path VERIFIED) |
| M0.5 | Pi baseline | `done` |
| M0.6 | Audio routing ADR | `done` |

---

## M1–M3 — `done`

Scaffold, config, WS, vision client, attention machine, deploy/doctor — shipped and tested.

---

## M4 — Audio pipeline — `in_progress`

- [x] Capture + 3 s ring
- [x] Stream pre-roll + `maxMs` hard stop
- [x] Wake refractory 2 s + force/inject bypasses
- [x] VAD (energy with hysteresis; Silero optional)
- [ ] Train `hey_comstar.onnx` + ROC table
- [ ] Hardware UAT (3 m / TV)

---

## M5 — AO session — `in_progress`

- [x] Session manager + greeter/voice overlays
- [x] Guest MCP excludes `home_assistant`
- [x] Live greeter/voice against `10.0.10.16`
- [x] Terminal MCP server stub (`mcp/terminal_mcp/server.py`)
- [ ] Wire tunnel bootstrap into `ComstarMcpBootstrap`
- [ ] Vision MCP hosted registration

---

## M6 — Voice round trip — `in_progress`

- [x] STT client + local server
- [x] TTS Piper/FakeTts + fallback WAVs
- [x] Coordinator wiring + `speak.ended` watchdog
- [x] Follow-up window (listen without wake)
- [x] `scripts/latency_report.py`
- [x] Prefer Reach `SpeechClient` when AO advertises `hello.speech` (ADR 0003)
- [x] Env URL fallback (`COMSTAR_STT_URL` / `COMSTAR_TTS_URL`) for Mac/dev
- [x] Pi-local STT/TTS units retained as optional fallback
- [ ] ≥10 labeled live-bridge STT fixtures + `--require-live 10` (re-bench vs Ada)
- [ ] 20 consecutive spoken UAT
- [ ] Disable always-on Pi `comstar-stt`/`comstar-tts` once Ada speech proven in prod

---

## M7 — Avatar & kiosk — `in_progress`

- [x] Kiosk shell + Chromium unit (`/opt/comstar/src`)
- [x] HTMLAudioElement speak path + state visuals
- [x] ADR 0002 render path (local)
- [ ] GLB TalkingHead lip-sync
- [ ] Pi fps measurement in BASELINES

---

## M8 — First contact — `in_progress`

- [x] Full software wiring on Pi (bridge+audio+kiosk active)
- [x] Greeter half-duplex + cache
- [x] `enroll_face.sh`
- [ ] Enroll real user (needs face in frame) — `zlatko` enrolled on CPAI; re-verify walk-up
- [ ] Walk-up UAT-8

---

## M9 — Hardening — `not_started`

Failure matrix, soak, privacy audit.

---

## Definition of done (Phase 1)

> Walk into the room, be greeted by name within two seconds, ask a question in plain speech without touching anything, and get a spoken, lip-synced answer in under fifteen seconds — reliably, for a week, with the outside network unplugged.

**Software path is deployable and live-tested against AO + CPAI.** Hardware UATs (enroll, wake ROC, GLB lip-sync, soak) remain.

---

## Next concrete actions

1. Collect ≥10 labeled live-bridge STT fixtures; run `bench_stt --require-live 10`
2. Fast-speech UAT after VAD hysteresis (`COMSTAR_VAD_SILENCE_MS=1200`)
3. Train or obtain `models/hey_comstar.onnx` (or run with `COMSTAR_FORCE_WAKE_SCORE=0.99`)
4. Drop a GLB at `assets/comstar.glb` and wire TalkingHead
5. Run M9 soak
