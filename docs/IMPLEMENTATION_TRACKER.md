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
| Active milestone | **M4 / M6 / M7 remaining** (M0≈90%, M1–M3 done, M5 session code + AO hello verified) |
| Overall Phase 1 | ~60% |
| Last updated | 2026-08-02 |
| Board | `comstar-ai` Pi 4B 4GB @ `192.168.89.34` (Dart 3.5.4, Node 18, jq, linger on) |
| Vision backend | CodeProject.AI `10.0.10.16:32168` (GPU YOLO + Face) |
| AO Reach | `10.0.10.16:8765` v1.27.4 — `spike/reach_hello.dart` → `Hello.` |
| Product code | bridge (vision+attention+session+stt/tts), audio bring-up, kiosk audio playback |
| Packaging | `deploy/deploy.sh`, `scripts/stt_server.py`, `docs/RUNBOOK.md`, dev inject `:8779` |
| Tests | **60** Dart + **2** Python — green on Mac and Pi |

### Remaining before Phase 1 exit

- Wake-word ONNX train + ROC (M4) — `train_wakeword.py` is a placeholder; stub never fires
- TalkingHead GLB lip-sync (M7) — kiosk plays `audioUrl`; `#avatar` container ready
- 24 h soak + failure matrix (M9)
- Face enrollment on hardware (M8) — script ready, no users enrolled yet

### Open blockers / gaps

| ID | Item | Blocks | Owner note |
|---|---|---|---|
| B1 | ~~Dart/Node/jq missing on Pi~~ | — | **Resolved** — Dart 3.5.4, Node 18, jq installed |
| B2 | ~~linger disabled~~ | — | **Resolved** — `loginctl enable-linger md-admin` |
| B3 | ~~AO Reach not verified~~ | — | **Resolved** — overlay+tunnel+directAgent |
| B4 | ~~faster-whisper / STT HTTP not found on LAN~~ | — | **Mitigated** — `scripts/stt_server.py` + `make stt-dev`; set `COMSTAR_STT_URL` |
| B5 | ~~Audio routing ADR~~ | — | **Resolved** — kiosk sink (ADR 0001) |
| B6 | No faces enrolled | M8 greet-by-name | `scripts/enroll_face.sh` ready |
| B7 | SSH keys / full Makefile DEV_LOOP | iteration speed | password SSH works; keys still preferred |
| B8 | Wake word model not trained | M4 exit | stub never fires; `train_wakeword.py` placeholder |
| B9 | TalkingHead GLB not integrated | M7 lip-sync | kiosk plays `audioUrl`; GLB next |

---

## Milestone rollup

| # | Name | Effort | Status | Progress | Gate |
|---|---|---|---|---|---|
| M0 | Ground truth | 6h | `in_progress` | ~80% | verify services; no product code |
| M1 | Skeleton & config | 8h (+3h DEV_LOOP) | `done` | 100% | three processes + make doctor |
| M2 | Vision client | 10h | `done` | 100% | offline tests + live recognize |
| M3 | Attention state machine | 12h (+4h console) | `done` | 100% | 100% branch coverage |
| M4 | Audio pipeline | 14h | `in_progress` | ~30% | wake ROC + hardware UAT |
| M5 | AO Reach session | 12h | `in_progress` | ~50% | text turn + no overlay leak |
| M6 | Voice round trip | 10h | `in_progress` | ~50% | p95 turn &lt; 15s, no avatar |
| M7 | Avatar & kiosk | 14h | `in_progress` | ~15% | lip-sync + render ADR |
| M8 | First contact | 10h | `not_started` | 0% | walk-up demo UAT-8 |
| M9 | Hardening & soak | 16h | `not_started` | 0% | 24h soak + runbook |

---

## Preflight (before / alongside M0–M1)

Environment work already partly done during bring-up. Track the rest here.

- [x] Pi identified and documented (`docs/BASELINES.md`)
- [x] OS fully upgraded (Bookworm, kernel 6.12.96, EEPROM current)
- [x] Ethernet preferred default route (metric 100 / 600)
- [x] USB camera present and capturing (Logitech C525 `/dev/video0`)
- [x] Mic capturing (C525 USB audio)
- [x] HDMI panel connected (1024×768)
- [x] CodeProject.AI reachable; Object Detection + Face on **GPU**
- [x] Face-miss shape observed (`userid: "unknown"`)
- [ ] SSH key + `~/.ssh/config` Host `comstar` (no password in scripts)
- [ ] `ai-server.lan` → `10.0.10.16` on Mac and Pi
- [ ] Install Dart ^3.5, Node/npm, jq on Pi (and Mac as needed)
- [ ] `loginctl enable-linger md-admin`
- [ ] Confirm AO daemon ≥ v1.27.0 + `AGENTIC_SERVE_SESSION_OVERLAY` + `AGENTIC_SERVE_MCP_TUNNEL`
- [ ] Confirm faster-whisper HTTP endpoint

---

## M0 — Ground truth

**Goal:** every verifiable `SPEC` in CONTRACTS becomes `VERIFIED`. No product code.  
**Status:** `in_progress`

### Tasks

| ID | Task | Status | Notes |
|---|---|---|---|
| M0.1 | `scripts/verify_cpai.sh` + fixtures | `not_started` | Manual probes done; script/fixtures not committed |
| M0.2 | GPU + contention baselines | `in_progress` | GPU confirmed; loaded-vs-idle p95 not recorded |
| M0.3 | `ao_reach` API + `spike/reach_hello.dart` | `not_started` | **Highest risk** |
| M0.4 | TalkingHead API → CONTRACTS §9 | `not_started` | Desktop Chrome smoke |
| M0.5 | Pi baseline → `docs/BASELINES.md` | `done` | 2026-08-02 |
| M0.6 | Audio routing ADR | `not_started` | Decide (a) kiosk vs (b) ALSA |

### Exit criteria

- [ ] Real CPAI JSON captured: detection hit, face hit, face miss → `docs/fixtures/`
- [x] Miss-shape question answered in writing (`userid: "unknown"`) — also put in CONTRACTS when updating
- [x] Both CPAI modules confirmed on CUDA/GPU
- [ ] Loaded vs unloaded detection p95 in BASELINES
- [ ] `spike/reach_hello.dart` printed a real orchestrator response
- [ ] TalkingHead spoke a line in desktop Chrome; CONTRACTS §9 written
- [ ] `docs/adr/0001-audio-routing.md` written; losing option removed from CONTRACTS
- [x] `docs/BASELINES.md` populated

### Deliverables checklist

- [ ] `scripts/verify_cpai.sh`
- [ ] `spike/reach_hello.dart`
- [x] `docs/BASELINES.md`
- [ ] `docs/fixtures/cpai_*.json`
- [ ] `docs/adr/0001-audio-routing.md`
- [ ] `docs/CONTRACTS.md` updated (§3, §4, §6 → VERIFIED, new §9)

---

## M1 — Skeleton & config

**Status:** `not_started` · **Effort:** 8h + 3h remote DEV_LOOP

### Exit criteria

- [ ] `dart analyze`, `ruff`, `mypy --strict` clean
- [ ] All three processes start under systemd and stay up 10 minutes
- [ ] Killing bridge → audio/kiosk reconnect within 5 s
- [ ] JSON logs one object per line
- [ ] `systemctl stop` &lt; 2 s for all three
- [ ] `make doctor` passes from Mac
- [ ] `make logs` merged/coloured on Mac
- [ ] `make deploy` &lt; 60 s; broken build auto-rolls-back
- [ ] `make bridge-dev` accepts Pi audio connection
- [ ] Dev mode refuses bad/missing `COMSTAR_ENV` / `lan_token`

### Key tasks to tick when done

- [ ] M1.1 Repo scaffold + gitignore / tooling configs
- [ ] M1.2 Typed config loader (unknown keys fatal)
- [ ] M1.3 Structured logger (Dart + Python)
- [ ] M1.4 Local WS server `:8777` / `:8778`
- [ ] M1.5 WS clients with backoff
- [ ] M1.6 SIGTERM + systemd units
- [ ] M1.7 Remote DEV_LOOP (Makefile, doctor, deploy, bridge-dev, colorlog)

---

## M2 — Vision client

**Status:** `not_started` · **Effort:** 10h

### Exit criteria

- [ ] All vision tests green with zero network
- [ ] Live: userid resolves within 2 s; recognize ~once not per frame
- [ ] 30 min: memory growth ≤ 10 MB, no fd growth
- [ ] `vision.degraded` on CPAI stop; clears on restart

### Key tasks

- [ ] M2.1 Frame grabber (long-lived process, drop not queue)
- [ ] M2.2 CPAI client (empty on error, never throw)
- [ ] M2.3 Vote-based identity resolver
- [ ] M2.4 Poll loop (recognize only when needed)
- [ ] M2.5 Fake CPAI from M0 fixtures

---

## M3 — Attention state machine

**Status:** `not_started` · **Effort:** 12h + 4h dev console

### Exit criteria

- [ ] 100% branch coverage on `machine.dart`
- [ ] Property test 10,000 random sequences
- [ ] All golden scenarios pass
- [ ] Zero `await` inside `handle()`
- [ ] Console harness walks full ladder by hand

### Key tasks

- [ ] M3.1 Sealed events/states
- [ ] M3.2 Pure machine → Effects as data
- [ ] M3.3 Effect runner (dispatch, never await in transition)
- [ ] M3.4 Six invariants
- [ ] M3.5 Turn ID lifecycle
- [ ] M3.6 Timers via injected Tick
- [ ] M3.7 Dev console `:8779` + event injection

---

## M4 — Audio pipeline

**Status:** `not_started` · **Effort:** 14h

### Exit criteria

- [ ] Zero false accepts on 60 min room recording
- [ ] ≥ 90% detection at 3 m on-axis quiet
- [ ] ≥ 70% detection at 3 m with TV
- [ ] ROC table in BASELINES
- [ ] CPU &lt; 15% of one core idle Ambient

### Key tasks

- [ ] M4.1 Capture + 3 s ring buffer (never to disk)
- [ ] M4.2 Train `hey comstar` onnx
- [ ] M4.3 Wake runtime + refractory
- [ ] M4.4 Silero VAD + pre-roll
- [ ] M4.5 Stream 320 ms PCM frames
- [ ] M4.6 Playback only if ADR chose (b)
- [ ] M4.7 Threshold sweep / ROC

---

## M5 — AO Reach session

**Status:** `not_started` · **Effort:** 12h

### Exit criteria

- [ ] Typed Q → answer, p95 &lt; 10 s
- [ ] No markdown/lists/URLs in spot-check of 20 answers
- [ ] 20 open/close → zero residual `client.*` overlays
- [ ] `who_is_present` callable with real data
- [ ] Guest cannot reach `home_assistant`

### Key tasks

- [ ] M5.1 Session manager (stop on SIGTERM / identity change)
- [ ] M5.2 Overlay agents + spoken-output test
- [ ] M5.3 Guest / restricted mode
- [ ] M5.4 Terminal MCP (tunnelled)
- [ ] M5.5 Vision MCP (hosted, not tunnelled)

---

## M6 — Voice round trip

**Status:** `not_started` · **Effort:** 10h

### Exit criteria

- [ ] 20 consecutive spoken questions answered
- [ ] p50 `turn_total` &lt; 8 s, p95 &lt; 15 s
- [ ] Latency report shows orchestration dominating
- [ ] Fallback lines play with network unplugged
- [ ] Wake word cannot fire during playback

### Key tasks

- [ ] M6.1 STT client (streamed)
- [ ] M6.2 TTS Piper (first-chunk streaming)
- [ ] M6.3 Wire runner effects
- [ ] M6.4 Offline fallback WAVs
- [ ] M6.5 Latency spans + report script
- [ ] M6.6 Half-duplex barge-in policy

---

## M7 — Avatar & kiosk

**Status:** `not_started` · **Effort:** 14h

### Exit criteria

- [ ] ≥ 24 fps on chosen render path
- [ ] Lip-sync acceptable on 10 utterances
- [ ] `docs/adr/0002-render-path.md` written
- [ ] Kiosk kill mid-utterance does not wedge bridge
- [ ] GLB failure still allows spoken conversation

### Key tasks

- [ ] M7.1 Kiosk shell / Chromium
- [ ] M7.2 TalkingHead + `speak.started` / `speak.ended`
- [ ] M7.3 State visuals
- [ ] M7.4 Render path ADR (local vs streamed)
- [ ] M7.5 Failure behaviour
- [ ] M7.6 Reconnect resilience

---

## M8 — First contact

**Status:** `not_started` · **Effort:** 10h

### Exit criteria

- [ ] 10/10 walk-up greetings
- [ ] Greeting p95 &lt; 2 s from face in frame
- [ ] `turn_total` p95 &lt; 15 s across 20 questions
- [ ] Follow-up window feels natural
- [ ] Guest restricted; no personal data leak
- [ ] Non-author can use without instructions

### Key tasks

- [ ] M8.1 Full wiring
- [ ] M8.2 Greeting flow (&lt; 1.5 s target)
- [ ] M8.3 Follow-up window
- [ ] M8.4 Stranger modes
- [ ] M8.5 `enroll_face.sh` from terminal camera
- [ ] M8.6 Demo mode overlay

---

## M9 — Hardening & soak

**Status:** `not_started` · **Effort:** 16h

### Exit criteria

- [ ] 24 h unattended: zero crashes / interventions
- [ ] ≤ 2 false wake accepts in 24 h
- [ ] Memory and fd count flat within 5%
- [ ] Every failure-matrix row recovers automatically
- [ ] `docs/RUNBOOK.md` complete
- [ ] Privacy audit matches README claims

### Key tasks

- [ ] M9.1 Failure matrix
- [ ] M9.2 Reconnect/backoff everywhere
- [ ] M9.3 systemd MemoryMax / WatchdogSec
- [ ] M9.4 24 h soak
- [ ] M9.5 Retune wake from soak data
- [ ] M9.6 Runbook
- [ ] M9.7 Privacy audit

---

## Definition of done (Phase 1)

> Walk into the room, be greeted by name within two seconds, ask a question in plain speech without touching anything, and get a spoken, lip-synced answer in under fifteen seconds — reliably, for a week, with the outside network unplugged.

---

## Deferred (do not pull into Phase 1)

Track in `docs/BACKLOG.md` when created — not here as active work:

- Custom rigged COMSTAR avatar  
- Full-duplex barge-in with AEC  
- Sentiment → gesture mapping  
- Multi-user simultaneous presence  
- House-wide presence via existing cameras  
- Session handoff between terminals  
- Morning briefing / email / Slack triage  

---

## How to update this file

1. Set milestone `Status` and rollup `Progress`.  
2. Check exit criteria with a date in the commit message when closing a milestone.  
3. Move resolved blockers out of the Open blockers table (or mark resolved).  
4. Keep CONTRACTS verification status in sync when M0 closes.

**Next concrete actions (recommended order):**

1. Finish M0.1 script + commit CPAI fixtures (including miss JSON).  
2. Update CONTRACTS §3 with verified shapes / miss behaviour.  
3. M0.3 `reach_hello.dart` against live AO.  
4. M0.4 TalkingHead + M0.6 audio ADR.  
5. Close M0 → start M1 scaffold + DEV_LOOP.
