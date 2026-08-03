# CONTRACTS

Every interface that crosses a process, machine, or trust boundary. If you change
anything here, you change it here **first**, then in code, then in the tests.

Status legend: `SPEC` = designed, not yet verified against the real thing.
`VERIFIED` = confirmed against a running service, with the date.

---

## 1. Bridge ↔ Kiosk (local WebSocket)

**Transport:** `ws://127.0.0.1:8777`. No auth — loopback only, bound explicitly to
`127.0.0.1`, never `0.0.0.0`. Bridge is the server, kiosk is the client and
reconnects with backoff.

**Status:** SPEC

> **Dev-mode exception.** During development the bridge runs on the Mac and the Pi's
> processes connect over the LAN (`docs/DEV_LOOP.md` §1, Loop B). This binds to the
> LAN interface instead of loopback, which production must never do. Three gates, all
> required simultaneously: `COMSTAR_ENV=dev`, a matching `dev.lan_token` on every
> connection, and a config file named `comstar.dev.yaml` rather than `comstar.yaml`.
> A T0 test asserts `comstar.example.yaml` ships with `dev.bind_lan: false`. The
> bridge logs a `warn` on every dev-mode start naming the bound interface. Ports
> 8779 (dev console) and the VM service port are subject to the same gates.

### Envelope

Every message, both directions:

```json
{ "v": 1, "id": "msg_01J...", "type": "<type>", "ts": 1754160000000, "turn_id": "t_01J...", "data": { } }
```

`turn_id` is null outside a turn. `id` is ULID. Unknown `type` is logged and
ignored, never fatal — this is how we ship kiosk and bridge independently.

### Bridge → Kiosk

| type | data | meaning |
|---|---|---|
| `state` | `{state, userid?, displayName?}` | Attention state changed. Kiosk adjusts idle animation / gaze. |
| `speak` | `{text, audioUrl, visemes?, mood?}` | Render this utterance. `audioUrl` is a loopback HTTP URL served by the bridge. |
| `speak.cancel` | `{}` | Barge-in or timeout. Stop immediately, return to idle. |
| `listening` | `{active, level?}` | Show/hide listening indicator; `level` 0–1 for a mic meter. |
| `thinking` | `{active}` | Orchestration in flight. Kiosk shows a subtle working state. |
| `error` | `{code, message}` | Display a non-fatal error affordance. |
| `config` | `{avatarUrl, mood, cameraPose}` | Sent once on connect. |

### Kiosk → Bridge

| type | data | meaning |
|---|---|---|
| `ready` | `{avatarLoaded, webglVendor, fps}` | Sent when the avatar GLB has loaded. Bridge will not enter Engaged before this. |
| `speak.started` | `{}` | First audio frame played. Bridge closes the `avatar_start` span here. |
| `speak.ended` | `{}` | Playback complete. Bridge opens the follow-up window here, **not** when TTS finished generating. |
| `span` | `{name, ms}` | Kiosk-side timing. |
| `error` | `{code, message}` | Render failure, GLB load failure, WebGL context loss. |

**Critical ordering rule:** the follow-up window opens on `speak.ended` from the
kiosk, never on a bridge-side timer. If the kiosk dies mid-utterance the bridge
must time out at `tts_total + 5s` and return to Ambient rather than hang.

---

## 2. Bridge ↔ Audio (local WebSocket)

**Transport:** `ws://127.0.0.1:8778`. Same envelope as §1.

**Status:** SPEC

### Audio → Bridge

| type | data | meaning |
|---|---|---|
| `wake` | `{score, model}` | Wake word fired above threshold. |
| `vad.speech_start` | `{}` | Silero detected speech onset. |
| `vad.speech_end` | `{durationMs}` | `vad_silence_ms` of silence elapsed. |
| `audio.chunk` | binary frame | 16 kHz mono PCM s16le, 320 ms per frame. Sent as WS binary, correlated by the preceding `audio.begin`. |
| `audio.begin` | `{turn_id, sampleRate, encoding}` | Precedes the binary stream. |
| `audio.end` | `{frames, totalMs}` | Stream complete. |
| `level` | `{rms}` | 10 Hz mic level for the UI meter. |
| `error` | `{code, message}` | Device lost, model load failure. |

### Bridge → Audio

| type | data | meaning |
|---|---|---|
| `listen.start` | `{turn_id, maxMs}` | Begin streaming captured audio. |
| `listen.stop` | `{}` | Stop capture (timeout, cancel, or barge-in resolution). |
| `wake.enable` | `{enabled}` | Disabled during playback in half-duplex mode. |
| `play` | `{audioUrl, turn_id}` | Play this file on the speaker. Used only if the kiosk is not the audio sink — see §6. |
| `mute` | `{muted}` | Software mute. Reflected in `mic_status` MCP tool. |

---

## 3. Bridge → CodeProject.AI

**Base:** `http://<ai-server>:32168`. Multipart form posts.

**Status:** VERIFIED — face miss returns `userid: "unknown"` in predictions
(2026-08-02, fixture `docs/fixtures/cpai_recognize_miss_person.json`). Empty
predictions or `success: false` also treated as miss.

### Object detection

```
POST /v1/vision/detection
  image           file
  min_confidence  float
```

Expected response shape:

```json
{
  "success": true,
  "predictions": [
    {"label":"person","confidence":0.91,"x_min":120,"y_min":40,"x_max":410,"y_max":700}
  ],
  "inferenceMs": 31,
  "processMs": 44
}
```

Bridge only cares about `predictions[].label == "person"` above
`vision.person_confidence`.

### Face recognition

```
POST /v1/vision/face/recognize
  image           file
  min_confidence  float
```

```json
{
  "success": true,
  "predictions": [
    {"userid":"zlatko","confidence":0.87,"x_min":180,"y_min":60,"x_max":320,"y_max":240}
  ]
}
```

`userid == "unknown"` (or an empty predictions array, or `success: false`) means
no match. **All three cases must be handled** — M0 confirmed the live module
returns `userid: "unknown"` when a face is present but not enrolled (see fixture
above).

### Face registration

```
POST /v1/vision/face/register
  userid   string
  image1   file
  imageN   file
```

### Face list

```
POST /v1/vision/face/list
→ {"success":true,"faces":["zlatko", ...]}
```

### Error handling contract

- Non-2xx, or `success:false` → treat as *no detection*, never as an exception that
  breaks the poll loop. Log at `warn`, increment a counter, continue.
- Timeout: 2000 ms for detection, 3000 ms for recognize. A CPAI queue backup must
  degrade COMSTAR's responsiveness, not crash it.
- Three consecutive failures → emit `vision.degraded`, drop to `ambient_fps`, and
  surface a subtle indicator on the kiosk.

---

## 4. Bridge → AO via `ao_reach`

**Status:** VERIFIED — AO v1.27.4 at `http://10.0.10.16:8765` with overlay +
MCP tunnel confirmed 2026-08-02 (`spike/reach_hello.dart` returns Hello).
COMSTAR overlays live-tested the same day: greeter ~0.85s (“Welcome, Zlatko!”),
voice_responder ~1.0s. Host MCP catalog ids: `fetch_url`, `filesystem_local`,
`home_assistant`, `media_audio_transcribe`, `media_understand`,
`media_video_analyze`. Do **not** request `memory` / `time` / `math` / `vision`
on this host — AO rejects the turn.

**Speech (AO ≥ 1.28 / Reach ≥ 0.2):** when `hello.speech.enabled` is true,
`SessionBridge.speechClient` is non-null. STT/TTS then use OpenAI-compatible HTTP
to the advertised sidecar URLs (AO-packaged on the AI server). PCM leaves the Pi
over LAN to those URLs — same trust boundary as CPAI/AO. Do **not** ferry PCM on
the Reach WebSocket or route turns through the planner solely for STT.
When `speechClient == null` (older AO, speech disabled, or session not started),
fall back to `COMSTAR_STT_URL` / `COMSTAR_TTS_URL` (local Pi or Mac bring-up).

### Connection

```dart
final bridge = SessionBridge();

await bridge.start(
  config: ReachConnectionConfig(
    baseUrl: cfg.orchestration.baseUrl,
    headers: {
      'x-agentic-user-name': identity.userid,
      'x-agentic-session-id': 'comstar-${identity.userid}',
      'x-warpgate-token': cfg.orchestration.token,
    },
    ttlSeconds: cfg.orchestration.ttlSeconds,
    // Optional when Ada sets AGENTIC_SPEECH_TOKEN:
    // speechToken: Platform.environment['COMSTAR_SPEECH_TOKEN'],
  ),
  overlayRoot: cfg.orchestration.overlayRoot,
  mcpBootstrap: ComstarMcpBootstrap(cfg),
);
```

### Turn

```dart
final result = await bridge.directAgent(
  agentProviderId: 'client.voice_responder',
  text: transcript,
  mcpProviderIds: ['client.terminal', 'vision', 'memory', 'home_assistant', 'time', 'math'],
);
```

### Speech (preferred path)

```dart
final speech = bridge.speechClient;
if (speech != null) {
  final text = await speech.transcribe(wavBytes);
  final wav = await speech.synthesize(replyText);
} else {
  // COMSTAR_STT_URL / COMSTAR_TTS_URL HTTP clients
}
```

Overlay / `direct_agent` must keep working when `speechClient == null`.

### Session lifecycle rules

- One `SessionBridge` per identity. Switching identity = `stop()` then `start()`.
- Sessions are **not** opened on Noticed. Only on Engaged, when there is a userid.
- Anonymous sessions use `x-agentic-user-name: guest` and the restricted overlay
  (`client.greeter` only, no `home_assistant`, no `memory`).
- `stop()` must be called on SIGTERM. Overlay leakage on the daemon is a real
  failure mode — the bridge registers `client.*` agents and must clear them.

### Overlay agents

`overlays/comstar/agent_providers/voice_responder.yaml` — the conversational agent.
Its system prompt must include a spoken-output constraint: no markdown, no lists,
no URLs, target 40 words, because this text goes to a TTS engine and then to a
person standing in a room.

`overlays/comstar/agent_providers/greeter.yaml` — generates the Engaged greeting.
Separate agent because it must be fast (target <1.5s) and has a much smaller MCP
set (`memory`, `time` only).

---

## 5. MCP tools exposed by COMSTAR

### Hosted, server-side (`mcp/vision_mcp/`)

Wraps CodeProject.AI. Runs on the AI server, registered as a plain HTTP MCP — **not**
through the reverse tunnel, because it is co-located with the daemon.

| tool | args | returns |
|---|---|---|
| `who_is_present` | `{}` | `{people: [{userid, confidence}], count}` |
| `describe_view` | `{}` | `{objects: [{label, confidence}]}` |
| `check_camera` | `{}` | `{ok, lastFrameAgeMs}` |

### Tunnelled, Pi-local (`mcp/terminal_mcp/`)

Reachable only from the Pi, exposed to the orchestrator over
`tunnel://session-mcp/terminal`.

| tool | args | returns |
|---|---|---|
| `set_display` | `{mode}` | `{ok}` — `mode` ∈ `avatar`, `clock`, `blank` |
| `play_tone` | `{tone}` | `{ok}` — `ack`, `error`, `attention` |
| `mic_status` | `{}` | `{muted, deviceOk, lastWakeAgoMs}` |
| `screen_state` | `{}` | `{on, brightness}` |
| `sleep_enter` | `{}` | `{ok, state:"sleeping"}` — COMSTAR dormant (not OS suspend) |
| `sleep_status` | `{}` | `{sleeping:bool}` |
| `volume_get` | `{}` | `{percent:0-100, muted:bool}` — HDMI/speaker sink |
| `volume_set` | `{percent:0-100}` | `{ok, percent, muted}` |
| `volume_adjust` | `{delta:-100..100}` | `{ok, percent, muted}` |
| `volume_mute` | `{muted:bool}` | `{ok, percent, muted}` |

Bridge loopback HTTP (127.0.0.1:8776) backs sleep/volume: `POST /control/sleep`,
`GET|POST /control/volume`. Guest sessions must **not** register `client.terminal`.

See `docs/adr/0004-terminal-control.md`.

## 6. Audio routing decision

**Status:** Resolved 2026-08-02 — **(a) Kiosk is the audio sink.** See
`docs/adr/0001-audio-routing.md`.

- TTS audio goes bridge → kiosk via loopback HTTP `audioUrl`; played by Chromium.
- Lip-sync stays on one clock; follow-up window opens on kiosk `speak.ended`.
- Bridge → audio `play` is **not used** in Phase 1 (reserved in §2 only).

---

## 7. Config schema

`config/comstar.yaml`. Parsed once at bridge start into a typed `ComstarConfig`.
**Fail fast and loud on an unknown key** — a typo'd threshold that silently uses a
default is a debugging nightmare on a device with no keyboard.

See `config/comstar.example.yaml` for the annotated version. Validation rules:

| key | rule |
|---|---|
| `vision.ambient_fps` | 0.2 ≤ x ≤ 5 |
| `vision.engaged_fps` | ambient_fps ≤ x ≤ 10 |
| `vision.person_confidence` | 0.3 ≤ x ≤ 0.95 |
| `vision.face_confidence` | 0.3 ≤ x ≤ 0.95 |
| `vision.recognize_votes` | 1 ≤ x ≤ 10 |
| `audio.wakeword_threshold` | 0.2 ≤ x ≤ 0.95 |
| `audio.vad_silence_ms` | 300 ≤ x ≤ 2000 |
| `audio.followup_window_seconds` | 0 ≤ x ≤ 30 |
| `orchestration.timeout_seconds` | 5 ≤ x ≤ 60 |
| `attention.stranger_mode` | enum: restricted \| greet \| ignore |
| `avatar.render` | enum: local \| streamed |

---

## 8. Attention state machine

The formal definition. `terminal/bridge/lib/attention.dart` implements exactly
this and nothing more.

### States

`ambient`, `noticed`, `engaged`, `listening`, `responding`, `sleeping`

Sleep is **not** OS suspend: processes keep running. In `sleeping`, vision and
speech (except wake word) are ignored until `WakeWord` exits to `listening`.

### Inputs (events)

| event | source |
|---|---|
| `PersonDetected(confidence)` | vision poll |
| `PersonAbsent` | vision poll, N consecutive frames with no person |
| `FaceRecognized(userid, confidence)` | vision poll |
| `FaceUnknown` | vision poll |
| `WakeWord(score)` | audio proc |
| `SpeechStart` / `SpeechEnd(durationMs)` | audio proc |
| `TranscriptReady(text)` | bridge STT call |
| `ResponseReady(text, audio)` | bridge AO + TTS |
| `PlaybackEnded` | kiosk |
| `Tick` | injected clock, 10 Hz |
| `Error(scope)` | any |
| `EnterSleep` | terminal MCP `sleep_enter` / control HTTP |

### Transition table

| from | event | guard | to | side effects |
|---|---|---|---|---|
| ambient | PersonDetected | conf ≥ person_confidence | noticed | raise vision poll to engaged_fps |
| ambient | WakeWord | score ≥ threshold | listening | open anonymous session, `listen.start` |
| noticed | FaceRecognized | votes reached, conf ≥ face_confidence | engaged | open AO session as userid, run greeter, cache identity |
| noticed | FaceUnknown | stranger_mode = greet | engaged | open guest session, restricted overlay |
| noticed | FaceUnknown | stranger_mode = restricted | noticed | no session; wake word still armed |
| noticed | PersonAbsent | absent ≥ 3 frames | ambient | drop poll to ambient_fps |
| engaged | WakeWord | — | listening | `listen.start`, disable wake (half-duplex) |
| engaged | SpeechStart | follow-up window open OR (face_attention_trigger AND gaze) | listening | `listen.start` |
| engaged | Tick | idle > identity_ttl AND absent | ambient | `SessionBridge.stop()` |
| listening | SpeechEnd | — | listening | finalize capture, call STT |
| listening | Tick | elapsed > max_utterance_seconds | responding | force-close capture with what we have |
| listening | TranscriptReady | text non-empty | responding | `thinking` on, call `directAgent` |
| listening | TranscriptReady | text empty | engaged | play `error` tone, `listen.stop` |
| responding | ResponseReady | — | responding | `speak` to kiosk |
| responding | PlaybackEnded | — | engaged | open follow-up window, re-enable wake |
| responding | Tick | elapsed > orchestration timeout | engaged | speak fallback line, re-enable wake |
| any (not sleeping) | EnterSleep | — | sleeping | stop listen, cancel follow-up, wake armed, ignore vision |
| sleeping | WakeWord | score ≥ threshold | listening | `listen.start` (keep session if open) |
| sleeping | PersonDetected / Face* / Speech* | — | sleeping | ignored |
| any | Error(fatal) | — | ambient | tear down session, log, re-arm |

### Invariants (asserted in tests, and at runtime in debug builds)

1. An AO session exists **iff** state ∈ {engaged, listening, responding}
   (session may remain open while `sleeping` until TTL/absent teardown on wake path).
2. Wake word is armed **iff** state ∉ {listening} and not (half-duplex and playing),
   **or** state is `sleeping` (always armed).
3. At most one in-flight `directAgent` call at any time.
4. `turn_id` is non-null **iff** state ∈ {listening, responding}.
5. Identity cache TTL is refreshed only by a positive `FaceRecognized`, never by
   `PersonDetected` alone.
6. No transition takes longer than 50 ms of wall clock inside the state machine
   itself — all I/O is dispatched, never awaited, inside a transition.
7. In `sleeping`, vision and VAD events are no-ops; only `WakeWord` exits.

---

## 9. Kiosk avatar (TalkingHead)

**Status:** VERIFIED (audio path) 2026-08-02 — GLB lip-sync still SPEC.

### Phase 1 audio path (shipping)

Kiosk `terminal/kiosk/avatar.js` plays `speak.audioUrl` with `HTMLAudioElement`.

| Event | When |
|---|---|
| `speak.started` | Immediately before `audio.play()` (or 1.2 s timer if `audioUrl` empty) |
| `speak.ended` | `audio.onended` / `onerror` / cancel |
| `ready` | On WS open — `{avatarLoaded, webglVendor, fps}` |

`#avatar` is a full-bleed mount. Without a GLB, the HUD + ambient gradient render;
spoken conversation still works (ADR 0001 kiosk sink).

### TalkingHead GLB path (next)

When `avatar.model` (`.glb`) is present and WebGL is healthy:

1. Load TalkingHead (or equivalent) into `#avatar`.
2. Drive lip-sync from the same `audioUrl` (or attached MediaElement source).
3. On WebGL context loss: fall back to HTMLAudioElement; keep `speak.*` events.
4. Bridge hang guard: if `speak.ended` missing after `tts_total + 5s`, force
   `PlaybackEnded`.

Pi fps / render-path ADR: `docs/adr/0002-render-path.md`.
