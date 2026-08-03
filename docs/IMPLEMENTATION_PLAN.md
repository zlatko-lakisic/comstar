# COMSTAR — Implementation Plan

**Audience:** an AI coding agent (Cursor / Claude Code) plus one human operator.
**Companions:** `AGENTS.md` (rules), `docs/CONTRACTS.md` (interfaces), `docs/TESTING.md` (test suite + UAT scripts), `docs/IMPLEMENTATION_TRACKER.md` (live status).

> **Architecture note (2026-08):** STT/TTS run on the Pi (`comstar-stt` / `comstar-tts`), not on the AI server. Vision (CPAI) and orchestration (AO) remain on the Ada host. Prefer the tracker + RUNBOOK over milestone text where they diverge.

---

## How to use this document

Work milestones in order. Do not start M(n+1) until M(n)'s exit criteria are all
checked. Each milestone has:

- **Goal** — one sentence, the thing that becomes true
- **Why here** — why this milestone sits at this point in the order
- **Tasks** — numbered `Mn.k`, each independently reviewable
- **Deliverables** — the files that exist afterwards
- **Automated tests** — what gets added to the regression suite
- **UAT** — what the human does to sign it off (full scripts in `docs/TESTING.md`)
- **Exit criteria** — the checklist that gates the next milestone
- **Risks** — what is most likely to go wrong here
- **Cursor prompt** — a starting prompt for the agent

Effort is in **ideal focused hours**, not calendar time. A solo evening project
runs at roughly 6–10 ideal hours per week.

---

## Milestone map

| # | Name | Effort | Ships |
|---|---|---|---|
| M0 | Ground truth | 6h | Verified facts about your actual services, no product code |
| M1 | Skeleton & config | 8h | Three processes that start, load config, log, and exit cleanly |
| M2 | Vision client | 10h | Dart client for CodeProject.AI, fully mocked and tested |
| M3 | Attention state machine | 12h | The heart of the product, pure logic, 100% tested offline |
| M4 | Audio pipeline | 14h | Wake word + VAD + capture on real hardware |
| M5 | AO Reach session | 12h | Identity-mapped sessions, overlay agents, one text turn end to end |
| M6 | Voice round trip | 10h | Speak → transcript → orchestration → spoken answer, no avatar |
| M7 | Avatar & kiosk | 14h | TalkingHead rendering, lip-synced, driven by the bridge |
| M8 | First contact | 10h | The full demo: walk up, get greeted, ask, get answered |
| M9 | Hardening & soak | 16h | Reconnects, degradation, 24h soak, systemd, false-accept tuning |

**Total ≈ 112 ideal hours.** Phase 2 items (custom avatar, AEC barge-in, multi-user,
house-wide presence) are deliberately out of scope here and get their own plan.

---

# M0 — Ground truth

**Goal:** every `SPEC` in `docs/CONTRACTS.md` that can be verified against your
running services becomes `VERIFIED`, with real captured responses.

**Why here:** this project depends on four external systems (CodeProject.AI,
`ao_reach`, TalkingHead, openWakeWord) whose exact behaviour we have assumed. Every
hour spent here saves several later. **No product code is written in M0.** The
output is probe scripts and updated documentation.

### Tasks

**M0.1 — CodeProject.AI probe** *(1.5h)*
Write `scripts/verify_cpai.sh`. It must:
- `GET /` and record the server version and module list
- `POST /v1/vision/detection` with a real photo containing a person; capture the
  full JSON response verbatim into `docs/fixtures/cpai_detection.json`
- `POST /v1/vision/face/list`; record whether it returns `{faces:[...]}` or
  something else
- Register a throwaway userid `_probe` with 3 images, then `face/recognize` with a
  4th; capture the response into `docs/fixtures/cpai_recognize_hit.json`
- `face/recognize` with a photo of a stranger; capture into
  `cpai_recognize_miss.json`. **This answers the open question in CONTRACTS §3:
  does a miss return `userid:"unknown"` or an empty array?**
- Delete `_probe`
- Time 20 sequential detection calls and record p50/p95 `inferenceMs`

**M0.2 — CodeProject.AI GPU + contention check** *(1h)*
- Confirm in the dashboard that **both** Object Detection and Face Processing report
  a CUDA execution provider, not CPU. Screenshot into `docs/fixtures/`.
- Run M0.1's timing loop twice: once with house cameras idle, once with them
  actively firing detections. Record both p95 numbers in `docs/BASELINES.md`.
- If the loaded p95 exceeds 400 ms, raise a decision: throttle COMSTAR, or run a
  second CPAI instance / dedicated module queue.

**M0.3 — `ao_reach` API confirmation** *(1.5h)*
- Pin a tag (`v0.1.0` or later — check `CHANGELOG.md` for the newest).
- Read `lib/` directly. Write down in `docs/CONTRACTS.md` §4 the **actual**
  signatures of `SessionBridge.start`, `directAgent`, `stop`, the
  `SessionMcpBootstrap` interface, and `McpSessionSpec`.
- Write a throwaway `spike/reach_hello.dart` that connects to the daemon, registers
  a trivial overlay agent, calls `directAgent` with "say hello", prints the result,
  and stops. **This is the single highest-risk unknown in the project.** If it
  doesn't work, everything after M5 is blocked and you want to know now.
- Confirm the daemon actually has `AGENTIC_SERVE_SESSION_OVERLAY=1` and
  `AGENTIC_SERVE_MCP_TUNNEL=1` set, and is ≥ v1.27.0.

**M0.4 — TalkingHead API confirmation** *(1h)*
- Clone TalkingHead, read its README and `modules/talkinghead.mjs`.
- Record in `docs/CONTRACTS.md` a new §9: the exact avatar-driving call you will
  use, its argument shape (audio buffer vs. URL, whether it wants word timings or
  visemes or can derive them), and how to trigger mood/gesture.
- Load a Ready Player Me sample GLB in desktop Chrome and speak one canned line.
  Confirm lip-sync works before you ever touch the Pi.

**M0.5 — Pi baseline** *(0.5h)*
- Record in `docs/BASELINES.md`: Pi model, RAM, OS version, kernel, `vcgencmd
  measure_temp` idle, USB camera enumeration (`v4l2-ctl --list-devices`), audio
  devices (`arecord -l`, `aplay -l`).
- Capture a 640×480 JPEG at 5 fps for 60 s and record CPU% and achieved fps.
- Run `speaker-test` and confirm audio out works.

**M0.6 — Close the audio routing decision** *(0.5h)*
Load Chromium on the Pi with a page that plays a 10 s WAV. Measure jitter and
dropouts. Decide CONTRACTS §6 (a) or (b). **Write the decision into
`docs/adr/0001-audio-routing.md`** and delete the losing option from CONTRACTS.

### Deliverables
```
scripts/verify_cpai.sh
spike/reach_hello.dart
docs/BASELINES.md
docs/fixtures/cpai_*.json
docs/adr/0001-audio-routing.md
docs/CONTRACTS.md          (updated: §3, §4, §6 → VERIFIED, new §9)
```

### Automated tests
None — M0 produces fixtures that later tests consume.

### UAT
`UAT-0` in `docs/TESTING.md`.

### Exit criteria
- [ ] Real CPAI JSON captured for detection hit, face hit, face miss
- [ ] The miss-shape question is answered in writing
- [ ] Both CPAI modules confirmed on CUDA
- [ ] Loaded vs. unloaded p95 recorded
- [ ] `reach_hello.dart` printed a real orchestrator response
- [ ] TalkingHead spoke a line in desktop Chrome
- [ ] Audio routing ADR written
- [ ] `docs/BASELINES.md` populated

### Risks
- **`ao_reach` is v0.1.0 with one commit.** It may be incomplete or have rough
  edges. If `reach_hello.dart` fails, the fix is likely in the SDK itself — budget
  for that, and note that you own the repo so you can fix it.
- **Face module on CPU.** Common. Turns a 40 ms call into 800 ms and quietly ruins
  the Engaged transition feel.

### Cursor prompt
> Read `AGENTS.md` and `docs/CONTRACTS.md`. We are in milestone M0 — verification
> only, no product code. Write `scripts/verify_cpai.sh` implementing tasks M0.1 and
> M0.2 exactly as specified in `docs/IMPLEMENTATION_PLAN.md`. It must be idempotent,
> must clean up the `_probe` userid on exit including on failure, must write raw
> responses to `docs/fixtures/`, and must print a summary table at the end. Do not
> guess at CodeProject.AI response shapes — the entire point of this script is to
> discover them.

---

# M1 — Skeleton & config

**Goal:** three processes start, parse the same config, log structured JSON,
connect to each other over loopback, and shut down cleanly on SIGTERM.

**Why here:** the cross-process plumbing is boring and it is where integration
bugs hide. Get it working while there is no logic to confuse it with.

### Tasks

**M1.1 — Repo scaffold** *(1h)*
Create the tree from `README.md` §Repository layout. Add `.gitignore`
(`config/comstar.yaml`, `.venv`, `node_modules`, `*.onnx`, `*.glb`, `docs/fixtures/*.jpg`).
Add `analysis_options.yaml`, `pyproject.toml` with ruff/black/mypy config,
`.editorconfig`.

**M1.2 — Typed config loader (Dart)** *(2h)*
`lib/config.dart`. Parse `config/comstar.yaml` into a `ComstarConfig` class with
nested typed sections. Implement the validation table from CONTRACTS §7.
**Unknown keys are a fatal startup error**, with a message naming the key and the
nearest valid key by edit distance.

**M1.3 — Structured logger** *(1h)*
`lib/log.dart` and `audio/log.py`. One JSON object per line, fields per
`AGENTS.md` §4. Level from `COMSTAR_LOG` env var, default `info`. A `Span` helper
that emits `AGENTS.md` §5 timing events on close.

**M1.4 — Local WS server (bridge)** *(2h)*
`lib/local_ws.dart`. Serves `127.0.0.1:8777` (kiosk) and `:8778` (audio).
Envelope encode/decode per CONTRACTS §1. Unknown message types logged and dropped.
Per-connection ULID. Heartbeat ping every 10 s, drop after 3 missed.

**M1.5 — Local WS clients** *(1.5h)*
`audio/bridge_client.py` and `kiosk/bridge_client.js`. Both reconnect with
exponential backoff capped at 5 s and jitter. Both send a `ready`-style hello on
connect.

**M1.6 — Lifecycle & systemd** *(0.5h)*
SIGTERM handler in all three: stop accepting, drain, close sockets, exit 0 within
2 s. Three unit files in `deploy/systemd/` with `Restart=on-failure` and
`RestartSec=5`.

**M1.7 — Remote dev loop** *(3h)* — see `docs/DEV_LOOP.md` for the full design
The Pi is headless and in another room; without this, every iteration costs you a
walk. Implement:
- Dev mode LAN binding for the local WS, gated on `COMSTAR_ENV=dev` **and**
  `dev.lan_token` **and** a config filename of `comstar.dev.yaml`. Add the T0 test
  asserting `comstar.example.yaml` has `dev.bind_lan: false`.
- `Makefile` with the target list in DEV_LOOP §8. Start with `doctor`, `logs`,
  `deploy`, `rollback`, `bridge-dev`, `kiosk-dev`, `audio-sync`.
- `scripts/colorlog.py` — merged, coloured, filterable log tail.
- Timestamped release directories with a `current` symlink, and **automatic rollback
  if any unit fails to come up within 30 s of a deploy.**
- `make doctor` implementing the DEV_LOOP §7 table, including the clock-skew check —
  latency spans across two machines are meaningless if NTP has drifted.

*Adds 3h to M1 (now 11h). It returns that within the first week.*

### Deliverables
```
terminal/bridge/lib/{config,log,local_ws}.dart
terminal/bridge/bin/comstar_bridge.dart
terminal/audio/{__main__.py,log.py,bridge_client.py}
terminal/kiosk/{index.html,bridge_client.js}
config/comstar.example.yaml
config/comstar.dev.example.yaml
deploy/systemd/comstar-{bridge,audio,kiosk}.service
deploy/{deploy.sh,rollback.sh}
Makefile
scripts/{colorlog.py,doctor.sh}
```

### Automated tests
- `config_test.dart` — valid config parses; every validation rule rejects an
  out-of-range value with a useful message; unknown key is fatal and suggests the
  nearest match; missing required key is fatal.
- `local_ws_test.dart` — envelope round-trip; unknown type dropped not thrown;
  malformed JSON dropped; heartbeat timeout closes the connection.
- `test_bridge_client.py` — reconnect backoff timing under a fake clock; hello sent
  on every reconnect, not just the first.

### UAT
`UAT-1`.

### Exit criteria
- [ ] `dart analyze`, `ruff`, `mypy --strict` all clean
- [ ] All three processes start under systemd and stay up 10 minutes
- [ ] Killing the bridge causes audio and kiosk to reconnect within 5 s
- [ ] `journalctl -u comstar-bridge -f` shows parseable JSON, one object per line
- [ ] `systemctl stop` returns in under 2 s for all three
- [ ] `make doctor` passes every row from the Mac
- [ ] `make logs` shows all three processes merged and coloured on the Mac
- [ ] `make deploy` completes in under 60 s; a deliberately broken build auto-rolls-back
- [ ] `make bridge-dev` on the Mac accepts a connection from the Pi's audio process
- [ ] Dev mode refuses to start with `COMSTAR_ENV` unset, and with a bad `lan_token`

### Risks
Low. If this milestone is hard, something is wrong with the environment, not the
design — resolve it now.

---

# M2 — Vision client

**Goal:** a tested Dart client for CodeProject.AI, plus a frame grabber, with a
poll loop that emits vision events. No state machine yet.

### Tasks

**M2.1 — Frame grabber** *(2h)*
`lib/camera.dart`. Spawn `libcamera-still`/`ffmpeg`/`v4l2` (whichever M0.5 showed
works) as a long-lived process producing JPEGs. **Do not spawn a process per
frame** — that costs ~200 ms each on a Pi 4. Emit `Uint8List` frames on a stream.
Configurable target fps with frame dropping (never queueing) when downstream is slow.

**M2.2 — CPAI client** *(3h)*
`lib/vision.dart`. `detectPerson(frame)` and `recognizeFace(frame)`. Typed models
`Detection` and `FaceMatch`. Timeouts per CONTRACTS §3. Errors return an empty
result, never throw. Consecutive-failure counter emitting `vision.degraded` at 3.

**M2.3 — Vote-based identity resolver** *(2h)*
`lib/identity.dart`. Accumulates `recognize_votes` consecutive matches for the same
userid above `face_confidence` before emitting `FaceRecognized`. A non-match or a
different userid resets the counter. Holds an identity with a TTL that is refreshed
only by positive recognition (CONTRACTS §8 invariant 5).

**M2.4 — Poll loop** *(2h)*
`lib/vision_poller.dart`. Runs detection at the current fps; only calls
`recognizeFace` when a person is present **and** identity is unresolved or expired.
Emits the vision events from CONTRACTS §8. fps switchable at runtime.

**M2.5 — Mock CPAI server** *(1h)*
`test/mocks/fake_cpai.dart`. Serves the M0 fixture responses, with injectable
latency, error rate, and scripted sequences ("person appears at frame 10, face
matches at 12, leaves at 40").

### Automated tests
- `vision_test.dart` — parses every M0 fixture correctly; 500 returns empty not
  throw; timeout returns empty; 3 failures emits degraded; recovery resets counter.
- `identity_test.dart` — needs exactly N votes; alternating userids never resolve;
  TTL expires under a fake clock; `PersonDetected` alone does not refresh TTL.
- `vision_poller_test.dart` — recognize is **not** called while identity is valid
  (this is the CPAI load protection, assert it hard); fps change takes effect within
  one period; frames are dropped not queued under slow downstream.
- `camera_test.dart` — process restart on unexpected exit; no fd leak over 1000
  simulated frames.

### UAT
`UAT-2`.

### Exit criteria
- [ ] All tests green with zero network access
- [ ] Against the real server: standing in front of the camera resolves your userid
      within 2 s, and the log shows recognize being called ~once, not per frame
- [ ] 30-minute run: no memory growth beyond 10 MB, no fd growth
- [ ] `vision.degraded` fires when you stop CPAI, clears when you restart it

### Risks
- **Recognize-per-frame is the classic mistake.** It will work fine in a 30-second
  test and melt your GPU queue in production. The test asserting it doesn't happen
  is more valuable than the feature.

---

# M3 — Attention state machine

**Goal:** CONTRACTS §8 implemented exactly, as pure logic with an injected clock,
with 100% branch coverage and every invariant asserted.

**Why here:** this is the product. Everything else is I/O. Because it is pure, it
can be tested exhaustively offline, and it should be — a state machine bug on a
device with no keyboard, in a hallway, at 11pm, is miserable to diagnose.

### Tasks

**M3.1 — Types** *(1.5h)*
`lib/attention/events.dart`, `states.dart`. Sealed classes for events and states.
Dart's exhaustive `switch` on sealed types is the point — a new event that isn't
handled becomes a compile error.

**M3.2 — Machine** *(4h)*
`lib/attention/machine.dart`. Constructor takes `Clock`, `ComstarConfig`, and an
`EffectSink`. `handle(Event) -> Transition`. **Side effects are returned as data,
never executed inside the machine.** `Transition` carries `from`, `to`, and a list
of `Effect` objects (`OpenSession`, `CloseSession`, `StartListening`, `Speak`,
`SetVisionFps`, `EnableWake`, …). This is what makes it testable.

**M3.3 — Effect runner** *(2.5h)*
`lib/attention/runner.dart`. The impure half: consumes `Effect`s and calls the real
subsystems. Dispatches, never awaits, so a slow effect can't block a transition
(invariant 6).

**M3.4 — Invariant assertions** *(1h)*
`lib/attention/invariants.dart`. All six from CONTRACTS §8, checked after every
transition. Throw in debug, log `error` + emit a metric in release.

**M3.5 — Turn ID lifecycle** *(1h)*
ULID minted on entering `listening`, cleared on leaving `responding`. Threaded into
every effect and every log line for that turn.

**M3.6 — Timers** *(2h)*
Follow-up window, `max_utterance_seconds`, orchestration timeout, identity TTL,
absence debounce. All driven off the injected `Tick`, no `Timer` objects — timers
you can't fast-forward are timers you can't test.

**M3.7 — Dev console with event injection** *(4h)* — see `docs/DEV_LOOP.md` §2
Served on `:8779` in dev mode, opened on the Mac. Live state ladder, identity and
confidence, camera thumbnail with the YOLO box, mic meter, last 20 transitions,
latency spans for the last 5 turns — plus buttons that inject synthetic events
straight into `handle(Event)`.

The injection panel is the point. The `TranscriptReady(text)` box alone means you can
test twenty phrasings of a question in a minute without speaking or walking into
frame. Injected events must route through the **same** entry point as real hardware
and be tagged `src: "injected"` in the logs, so a synthetic run can never be mistaken
for a real one.

*Adds 4h to M3 (now 16h). It pays back during M4–M8, where the alternative is
physically walking into camera frame several hundred times.*

### Automated tests
This is the milestone with the most tests. See `docs/TESTING.md` §T1.3 for the full
list. Highlights:
- Every row of the CONTRACTS §8 transition table gets a named test.
- **Property test:** feed 10,000 random event sequences; assert all six invariants
  hold after every single transition and the machine never throws.
- **Golden scenarios** as declarative fixtures — a YAML list of `(event, expected
  state, expected effects)` for: happy path, stranger arrives, two people arrive,
  wake word from an empty room, person leaves mid-question, orchestration timeout,
  kiosk dies mid-playback, wake word during playback (half-duplex), follow-up used,
  follow-up expired.
- **Timing tests under fake clock:** follow-up window is exactly N seconds; utterance
  cap fires; identity TTL expiry closes the session.

### UAT
`UAT-3` — a scripted console harness that lets you drive events by keypress and
watch the state, with no hardware attached.

### Exit criteria
- [ ] 100% branch coverage on `machine.dart` (this file, specifically, no excuses)
- [ ] Property test passes 10,000 sequences
- [ ] All golden scenarios pass
- [ ] Zero `await` inside `handle()` — enforced by a lint or a test that reflects
- [ ] The console harness lets you walk the whole ladder by hand

### Risks
- **Scope creep into the runner.** Logic must not leak out of `machine.dart` into
  `runner.dart`, because the runner is the untestable half. Review for this.

---

# M4 — Audio pipeline

**Goal:** wake word and VAD running on the real Pi with the real microphone, at a
tuned threshold, streaming captured audio to the bridge.

### Tasks

**M4.1 — Capture** *(2h)*
`audio/capture.py`. `sounddevice` or `pyaudio` at 16 kHz mono float32. Rolling
in-memory ring buffer of 3 s. **Never written to disk.** Device selection by name
with fallback and a loud log when it falls back.

**M4.2 — Wake word training** *(3h)*
`scripts/train_wakeword.py`. openWakeWord synthetic pipeline: generate `hey comstar`
positives with Piper across ≥8 voices, varied rate and pitch; augment with room
impulse responses; mix negatives from openWakeWord's standard negative corpus plus
a recording of your own room. Output `hey_comstar.onnx`. Record the training config
in `docs/BASELINES.md` so it's reproducible.

**M4.3 — Wake word runtime** *(2h)*
`audio/wakeword.py`. Feed 80 ms chunks, emit `wake` above threshold with a
refractory period of 2 s so one utterance can't double-fire. Enable/disable per
CONTRACTS §2.

**M4.4 — VAD** *(2h)*
`audio/vad.py`. Silero VAD. `speech_start` on onset, `speech_end` after
`vad_silence_ms`. Include the 500 ms of ring buffer *before* the wake word in the
captured utterance — people start talking before the wake word finishes.

**M4.5 — Streaming** *(2h)*
`audio/stream.py`. On `listen.start`, stream 320 ms PCM frames as WS binary per
CONTRACTS §2, so STT can begin before the user stops talking. Hard stop at
`max_utterance_seconds`.

**M4.6 — Playback** *(1.5h)*
`audio/playback.py` — only if the M0.6 ADR chose option (b). If (a), skip and delete
the `play` message from CONTRACTS §2.

**M4.7 — Threshold tuning** *(1.5h)*
Record 60 minutes of normal room audio (TV, conversation, kitchen). Sweep the
threshold from 0.3 to 0.9 in 0.05 steps offline against that recording plus 50 real
`hey comstar` utterances from across the room. Produce an ROC table in
`docs/BASELINES.md`. **Pick the lowest threshold with zero false accepts over the
hour**, then check the miss rate is acceptable. If it isn't, that's a microphone
problem, not a threshold problem.

### Automated tests
- `test_wakeword.py` — 50 positive clips ≥ 90% detection at chosen threshold; 60 min
  negative audio → 0 accepts; refractory period suppresses a double-fire.
- `test_vad.py` — speech_end fires within ±100 ms of `vad_silence_ms` on golden
  clips; a 200 ms cough does not trigger speech_start.
- `test_capture.py` — ring buffer never exceeds its bound; pre-roll included in the
  captured utterance; no file handles opened for writing.
- `test_stream.py` — frame count and total ms match the source; hard stop at cap.

### UAT
`UAT-4` — the room test. Includes speaking from 1 m, 3 m, off-axis, with the TV on,
and with music playing.

### Exit criteria
- [ ] Zero false accepts across the 60-minute room recording
- [ ] ≥ 90% detection at 3 m, on-axis, quiet room
- [ ] ≥ 70% detection at 3 m with TV at normal volume
- [ ] ROC table committed
- [ ] CPU under 15% of one core while idle in Ambient

### Risks
- **The Logitech's built-in mic will probably fail the 3 m tests.** If it does, that
  is the expected outcome, not a bug — order the ReSpeaker array and re-run. Do not
  compensate by dropping the threshold; you will trade misses for the TV waking the
  device at 2am, which is much worse.

---

# M5 — AO Reach session

**Goal:** face recognition opens an identity-mapped AO session, and a typed text
question returns a spoken-appropriate text answer.

### Tasks

**M5.1 — Session manager** *(3h)*
`lib/session.dart`. Wraps `SessionBridge` per CONTRACTS §4. Open on Engaged, close
on TTL expiry or identity change. Guarantees `stop()` on SIGTERM and on any fatal
error — **overlay leakage on the daemon is a real failure mode.**

**M5.2 — Overlay agents** *(2.5h)*
`overlays/comstar/agent_providers/voice_responder.yaml` and `greeter.yaml`. The
voice responder's prompt must forbid markdown, lists, and URLs, and target ~40
words. Write these constraints as an explicit test: `test/overlays_test.dart` asserts
the YAML contains the spoken-output clause, so nobody silently deletes it.

**M5.3 — Anonymous / restricted mode** *(1.5h)*
Guest sessions use `x-agentic-user-name: guest` and a restricted MCP set. Assert in
tests that `home_assistant` and `memory` are never in a guest session's
`mcpProviderIds`. This is a security boundary, not a preference.

**M5.4 — Terminal MCP (tunnelled)** *(3h)*
`mcp/terminal_mcp/`. Implements the four tools from CONTRACTS §5 and registers over
the reverse tunnel via `LocalMcpHost` / `McpSessionSpec`.

**M5.5 — Vision MCP (hosted)** *(2h)*
`mcp/vision_mcp/`. Server-side HTTP MCP wrapping CPAI. Deployed next to the daemon.
Registered as a plain hosted MCP, **not** through the tunnel.

### Automated tests
- `session_test.dart` — headers built correctly from a userid; identity change
  triggers stop-then-start in that order; SIGTERM path calls stop; guest session
  MCP list excludes the restricted set.
- `overlays_test.dart` — both YAMLs parse; voice responder contains the spoken-output
  constraint; greeter's MCP list is the small one.
- T3 integration (tagged, needs the real daemon): open a session, call
  `directAgent`, assert a non-empty response under 15 s, assert the overlay is
  cleared from the daemon afterwards.

### UAT
`UAT-5` — including the leak check: open and close 20 sessions, then inspect the
daemon and confirm zero `client.*` agents remain.

### Exit criteria
- [ ] Typed question → orchestrator answer, p95 under 10 s
- [ ] Answers contain no markdown, no bullet lists, no URLs (spot-check 20)
- [ ] 20 open/close cycles leave zero residual overlays
- [ ] `who_is_present` callable by the planner and returns real data
- [ ] Guest session provably cannot reach `home_assistant`

### Risks
- **Overlay leakage.** Worth a dedicated test, because the symptom (daemon slowly
  degrading over days) looks nothing like the cause.
- **The planner may not call `who_is_present` on its own.** If it doesn't, that's a
  prompt problem in the overlay, not a plumbing problem.

---

# M6 — Voice round trip

**Goal:** speak a question, hear an answer. No avatar, no face recognition — a black
screen and a voice.

**Why here:** it isolates the audio→STT→AO→TTS chain before adding rendering. When
something is slow later, you'll already know what this chain costs alone.

### Tasks

**M6.1 — STT client** *(2h)*
`lib/stt.dart`. Streams the audio frames from M4.5 to faster-whisper as they
arrive. Emits `TranscriptReady`. Empty or whitespace-only transcripts are handled
explicitly (they are common — the wake word fires, nobody speaks).

**M6.2 — TTS client** *(2.5h)*
`lib/tts.dart`. Piper via subprocess, streaming raw PCM. **First-chunk streaming is
the point** — start audio before the full utterance is synthesised. Cache the
greeting set, since those repeat constantly.

**M6.3 — Wire the runner** *(2h)*
Connect M3's `Effect`s to the real STT, AO and TTS clients.

**M6.4 — Fallback lines** *(1h)*
Pre-synthesised WAVs for: orchestration timeout, STT empty, vision degraded, AO
unreachable. These must never require the network to play, because the situations
where you need them are exactly the situations where the network failed.

**M6.5 — Latency instrumentation** *(1.5h)*
Every span from `AGENTS.md` §5 emitted with a shared `turn_id`. A
`scripts/latency_report.py` that reads a journal export and prints p50/p95 per span.

**M6.6 — Barge-in policy (half-duplex)** *(1h)*
Disable the wake word during playback. Add a physical/keyboard "stop" that cancels
playback and returns to Engaged.

### Automated tests
- `stt_test.dart` — golden audio → expected transcript (fuzzy match); empty audio →
  empty transcript, not an error; server 500 → fallback path.
- `tts_test.dart` — first chunk emitted before synthesis completes (assert with a
  fake clock); cache hit skips the subprocess; special characters don't break the
  pipe.
- `latency_test.dart` — spans nest correctly, `turn_total` ≥ sum of children,
  `turn_id` consistent across all spans in a turn.
- T3: end-to-end from a WAV file to output audio, asserting p95 `turn_total` < 15 s.

### UAT
`UAT-6`.

### Exit criteria
- [ ] 20 consecutive spoken questions all answered
- [ ] p50 `turn_total` under 8 s, p95 under 15 s
- [ ] Latency report shows orchestration dominating (if it doesn't, something else
      is wrong and you've just found it)
- [ ] Every fallback line plays with the network unplugged
- [ ] Wake word cannot fire during playback

---

# M7 — Avatar & kiosk

**Goal:** TalkingHead renders a lip-synced avatar on the Pi's screen, driven
entirely by bridge messages.

### Tasks

**M7.1 — Kiosk shell** *(2h)*
`kiosk/index.html`. Chromium in kiosk mode, cursor hidden, no scrollbars, correct
resolution for the panel. Autostart under systemd with a proper wayland/X session.

**M7.2 — TalkingHead wiring** *(4h)*
`kiosk/avatar.js`. Load the GLB, idle animation, and implement the `speak` message
using the API confirmed in M0.4. Emit `speak.started` on first audio frame and
`speak.ended` on completion — **the bridge's follow-up window depends on these
being accurate.**

**M7.3 — State visuals** *(2.5h)*
Idle (Ambient), attentive (Engaged), listening indicator with live mic level,
thinking indicator. Subtle — this is a device in a room, not a dashboard.

**M7.4 — Render path decision** *(2h)*
Measure achieved fps on the Pi at the panel's native resolution. If it holds ≥ 24
fps, keep `avatar.render: local` and delete `streamed` from the config. If not,
implement headless rendering on the A4000 with an H.264 stream to the Pi, and
delete `local`. **Write `docs/adr/0002-render-path.md` either way.**

**M7.5 — Failure behaviour** *(1.5h)*
WebGL context loss → reload. GLB load failure → fall back to a text-only display and
keep answering out loud. **The avatar must never be able to take down the voice
assistant.**

**M7.6 — Reconnect** *(2h)*
Kiosk survives a bridge restart, re-requests config, resumes. Bridge survives a
kiosk restart and does not hang waiting for `speak.ended`.

### Automated tests
- `kiosk/test/protocol.test.js` — every bridge→kiosk message type handled; unknown
  types ignored; `speak.cancel` mid-utterance stops playback and emits `speak.ended`.
- Headless Chrome (Playwright) smoke: loads, reports `ready` with a WebGL vendor,
  processes a canned `speak`, emits `speak.started` then `speak.ended` in order.
- `runner_test.dart` — bridge times out at `tts_total + 5s` when `speak.ended`
  never arrives, and returns to Engaged rather than hanging.

### UAT
`UAT-7`.

### Exit criteria
- [ ] Avatar renders at ≥ 24 fps on the chosen path
- [ ] Lip-sync visually acceptable on 10 varied utterances
- [ ] Render path ADR written and the losing option deleted from config
- [ ] Killing the kiosk mid-utterance does not wedge the bridge
- [ ] GLB load failure still lets you have a spoken conversation

---

# M8 — First contact

**Goal:** the demo. Walk up. Get greeted by name. Ask a question. Get a spoken,
lip-synced answer. Under 15 seconds.

**Why here:** every part exists; M8 is composition and the feel of the thing.

### Tasks

**M8.1 — Full wiring** *(2h)*
Vision poller → state machine → session → STT → AO → TTS → kiosk, all live.

**M8.2 — Greeting flow** *(2.5h)*
On Engaged, call the `greeter` agent with the userid and time of day. **Target under
1.5 s** — this is the moment that sells the product and latency here is felt far
more sharply than in an answer. Pre-cache the common greetings.

**M8.3 — Follow-up window** *(1.5h)*
After `speak.ended`, listen for `followup_window_seconds` with no wake word. Visual
indicator so it's discoverable. Tune the duration by feel in UAT.

**M8.4 — Stranger mode** *(1.5h)*
Implement all three `stranger_mode` values. Default `restricted`.

**M8.5 — Enrollment script** *(1.5h)*
`scripts/enroll_face.sh` — captures N frames from the **terminal's own camera**, at
the real distance and lighting, and posts them to CPAI. This is the difference
between recognition that works and recognition that doesn't.

**M8.6 — Demo mode** *(1h)*
A flag that overlays the current state, confidence, and last latency breakdown on
screen. Invaluable for debugging in situ and for showing people what it's doing.

### Automated tests
- Full scripted integration (T3): fake camera feeding a recorded video, fake mic
  feeding a WAV, real CPAI, real AO, real TTS. Asserts the state ladder is walked in
  order and `turn_total` p95 < 15 s.
- `greeting_test.dart` — greeting latency budget asserted; cache hit path; unknown
  user gets the restricted greeting.

### UAT
`UAT-8` — the full script, run at three different times of day and lighting
conditions. **This is the milestone you invite someone else to try.**

### Exit criteria
- [ ] 10/10 successful walk-up-and-be-greeted attempts
- [ ] Greeting latency p95 under 2 s from face entering frame
- [ ] `turn_total` p95 under 15 s across 20 questions
- [ ] Follow-up window works and feels natural (subjective, and that's fine)
- [ ] A guest gets restricted mode and no personal data leaks into their session
- [ ] Someone who is not you can use it without instructions

---

# M9 — Hardening & soak

**Goal:** it survives a week unattended.

### Tasks

**M9.1 — Failure matrix** *(4h)*
For each of: CPAI down, CPAI slow, AO down, AO slow, STT down, TTS down, kiosk dead,
camera unplugged, mic unplugged, network down, disk full — define and implement the
degraded behaviour, and write a test that injects it. Nothing may crash; everything
must recover automatically when the dependency returns.

**M9.2 — Reconnect and backoff everywhere** *(2h)*
Every client: exponential backoff with jitter, capped. No thundering herd on the
daemon when the network flaps.

**M9.3 — Resource limits** *(2h)*
`MemoryMax` and `CPUQuota` in the systemd units. Watchdog via `WatchdogSec` with
`sd_notify` heartbeats. A process that wedges must be killed and restarted, not left
silently alive.

**M9.4 — 24-hour soak** *(3h + 24h wall)*
Run in the real room, unattended. Collect: false wake accepts, CPAI error rate,
memory over time, fd count over time, temperature, unexpected restarts, state
distribution. Acceptance thresholds in `docs/TESTING.md` §T5.

**M9.5 — Threshold re-tune with real data** *(2h)*
Use the soak's false accepts to retrain/retune the wake word. Real household audio
beats any synthetic negative corpus.

**M9.6 — Operator docs** *(2h)*
`docs/RUNBOOK.md`: how to enroll a new face, re-tune the wake word, read the logs,
interpret the latency report, roll back a release, and the physical kill switch.

**M9.7 — Privacy audit** *(1h)*
Verify, by inspection and by test, every claim in the README's privacy model.
Specifically: no audio or frames on disk, nothing transmitted before wake or
session, the hardware kill actually kills. **If a claim isn't true, change the code
or change the README — don't leave the claim standing.**

### Exit criteria
- [ ] 24 h unattended: zero crashes, zero manual interventions
- [ ] ≤ 2 false wake accepts in 24 h
- [ ] Memory flat within 5% over 24 h; fd count flat
- [ ] Every failure-matrix row recovers automatically
- [ ] Runbook is complete enough that you could follow it in six months
- [ ] Privacy audit passes with no unverified claims

---

## Cross-cutting: what "done" looks like for the whole plan

You can walk into the room, be greeted by name within two seconds, ask a question in
plain speech without touching anything, and get a spoken, lip-synced answer in under
fifteen seconds — reliably, for a week, with the network to the outside world
unplugged.

---

## Deferred to Phase 2 (do not build these now)

Custom rigged COMSTAR avatar · full-duplex barge-in with AEC · sentiment→gesture
mapping · multi-user simultaneous presence · house-wide presence via existing camera
events · session handoff between terminals · morning briefing batch flow · email and
Slack triage.

Each of these is individually tempting and each one will slow M1–M9 down. They go in
`docs/BACKLOG.md`, not in this sprint.
