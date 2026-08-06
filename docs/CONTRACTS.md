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
> bridge logs a `warn` on every dev-mode start naming the bound interface. Port
> 8781 (admin + OAuth) LAN bind is gated separately via `COMSTAR_ADMIN_BIND_LAN`
> / `admin.bind_lan` (and OAuth’s own bind rules); the VM service port stays
> subject to the WS triple-gate.

### Admin console (`:8781/admin`) — VERIFIED 2026-08-04

Always-on HTTP in the bridge process (production and dev), sharing port **8781**
with Google Desktop OAuth. Path split:

| Prefix | Role |
|---|---|
| `/admin/*` | Ops UI + admin APIs |
| `/oauth/google/*` | Desktop Google OAuth (unchanged callbacks) |
| `/health` | Alias → `/admin/health` (heal script) |

**Bind:** `127.0.0.1` by default. Bind `0.0.0.0` when any of:

1. `admin.bind_lan: true` **and** a non-empty admin token, or
2. `COMSTAR_ADMIN_BIND_LAN=1` **and** `COMSTAR_ADMIN_TOKEN` (preferred on Pi), or
3. the WS LAN triple-gate is active (`devLanBindingEnabled`), or
4. Google OAuth would have bound LAN (`COMSTAR_OAUTH_BIND_LAN` / redirect base)

Token resolution (first non-empty): `COMSTAR_ADMIN_TOKEN` → `admin.token` →
`dev.lan_token`. When LAN-bound with a token, every `/admin/*` request except
`GET /admin/health` must present `X-Comstar-Lan-Token` or `?token=`. OAuth paths
never require the admin token.

| Route | Method | Auth | Meaning |
|---|---|---|---|
| `/admin/` | GET | token if LAN-bound | Static admin UI |
| `/admin/health` `/health` | GET | none | Attention/session/WS snapshot (heal script) |
| `/admin/api/status` | GET | token if LAN-bound | Extended status + host metrics + AO/CPAI probes |
| `/admin/api/logs` | GET | token if LAN-bound | SSE `journalctl --user` tail |
| `/admin/api/restart` | POST | token if LAN-bound | `{unit: bridge\|audio\|kiosk\|stt\|health\|all}` |
| `/admin/api/reboot` | POST | token if LAN-bound | `{confirm: "reboot"}` → `sudo /sbin/reboot` |
| `/admin/api/sleep` | POST | token if LAN-bound | `{action: enter\|exit}` |
| `/admin/inject` | POST | token if LAN-bound | Attention event inject; **403 unless `COMSTAR_ENV=dev`** |
| `/oauth/google/*` | * | none | Desktop OAuth start/callback/resend |

Restart units are whitelisted (`comstar-*.service` only). Loopback:
`ssh -L 8781:127.0.0.1:8781 comstar` → `http://127.0.0.1:8781/admin/`. LAN:
`http://<pi-ip>:8781/admin/?token=<admin-token>`.

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
| `pairing.qr` | `{active, phase?, url?, userCode?, qrSvg?}` | Show/hide Google OAuth device-code QR. `phase` is `awaiting` (user must approve), `verifying` (tokens received, tools starting), or `idle`. Same attempt as the spoken user code. `active:false` clears the overlay. |
| `error` | `{code, message}` | Display a non-fatal error affordance. |
| `config` | `{avatarUrl, mood, cameraPose}` | Sent once on connect. |
| `avatar.options` | `{bloom?, fps?, scale?, emblem?}` | Live avatar tuning (no kiosk restart). `bloom` SVG blur stdDeviation (`0` off); `fps` animation cap 8–60; `scale` emblem size; `emblem` preset name. Omitted fields unchanged. |

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

The CPAI `userid` string is the **biometric faceId** (enrolled as FreeIPA
`comstarFaceId`, defaulting to IPA `uid`). It is **not** automatically the AO
session identity — see §3b Directory resolve and ADR 0005.

### Face registration

```
POST /v1/vision/face/register
  userid   string   # = comstarFaceId (prefer IPA uid)
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

## 3b. Bridge → directory (FreeIPA via sidecar)

**Status:** Phase 2 — see ADR 0005 and `docs/ldap/`.

After the vote resolver emits a known faceId (and **before** `OpenSession`), the
bridge resolves the biometric id to a FreeIPA person:

```
GET {directory.sidecar_url}/v1/resolve?face_id=<comstarFaceId>
→ 200 {"uid":"zlatko","displayName":"Zlatko","groups":["comstar-users"],"dn":"..."}
→ 404 not found
→ 5xx / timeout → directory error
```

| outcome | `directory.require` | attention effect |
|---|---|---|
| 200 profile | — | `FaceRecognized(uid, conf, displayName)` → Engaged session as **uid** |
| 404 / error | `true` | `FaceUnknown` (guest / restricted per stranger_mode) |
| 404 / error | `false` | fail-open: treat faceId as uid (dev bring-up only) |
| `directory.enabled: false` | — | pass-through: faceId used as uid (no LDAP) |

Rules:

- IdentityResolver votes on **faceId** only; LDAP is never on the per-frame path.
- Session headers use **resolved `uid`**: `x-agentic-user-name: <uid>`,
  `x-agentic-session-id: comstar-<uid>`.
- Kiosk `state.displayName` and greeter prefer LDAP `displayName`/`cn`, else `uid`.
- Biometrics are never stored in LDAP. Planner LDAP MCP is deferred
  (`guest_allowed: false` when added).

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
      // identity.userid = FreeIPA uid after directory resolve (or faceId pass-through)
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

`overlays/comstar/` follows the AO catalog layout (`agent_providers/`,
`agent_skills/`, `agent_harnesses/`, `harnesses/`, `mcp_providers/`). See
`overlays/comstar/README.md`.

`agent_providers/voice_responder.yaml` — conversational agent. Spoken-output and
Google/tool guidance live in `agent_skills/` and are injected into `backstory` at
pack time (AO `direct_agent` does not attach skills today).

`agent_providers/greeter.yaml` — Engaged greeting (skill: `spoken_output`).
Separate agent because it must be fast (target <1.5s) and has an empty MCP set.
Live fallback when the phrase bank is empty.

`agent_providers/phrase_bank.yaml` — Batch writer for engage / sleep_enter /
sleep_wake / social text banks (optional `[[name]]` slots; not `{name}`, which AO
templates consume). Bridge refreshes `~/.cache/comstar/phrase_banks.json` on a
timer (`phrases.*` in config).

**Bridge-local voice short-circuits** (before `client.voice_responder`): sleep /
volume (`terminal_intent`), clock / date / season / timezone from the Pi system
clock (`clock_intent`; optional spoken label `attention.timezone` or
`COMSTAR_TZ`), and social check-ins (`social_intent` + social phrase bank). Do
not route these through AO `time` MCP.

**Conversation memory:** per recognized `userid` rolling transcript
(last `memory.max_turns` turns) plus durable facts (`memory.durable`) extracted
from “remember that…”, prefs, name, etc. Injected into AO voice prompts; guests
get none. Shared across terminals via `memory.url` →
`scripts/comstar_memory_server.py` (SQLite FTS for facts). This is COMSTAR-owned
RAG-lite — not AO `memory` MCP (still unavailable on this Ada host).

---

## 5. MCP tools exposed by COMSTAR

### Hosted, server-side (`mcp/ldap_mcp/`)

Wraps FreeIPA directory sidecar for the planner (P2.3). Does **not** open
sessions (ADR 0005). Overlay should set `guest_allowed: false`.

| tool | args | returns |
|---|---|---|
| `lookup_user` | `{uid}` | `{found, user?}` |
| `list_comstar_users` | `{limit?}` | `{users, count}` |

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

Bridge loopback HTTP (127.0.0.1:8776) backs sleep/volume/avatar: `POST /control/sleep`,
`GET|POST /control/volume`, `GET|POST /control/avatar` (live `bloom`/`fps`/`scale`/`emblem`
→ bridge pushes `avatar.options` to the kiosk). Guest sessions must **not** register
`client.terminal`.

**Avatar load governor (optional, default on):** bridge samples host CPU with the
health sparkline (~2 s). When EMA CPU ≥ `COMSTAR_AVATAR_CPU_STRESS` (default 75),
it steps bloom/fps down toward a floor; when CPU stays ≤ `COMSTAR_AVATAR_CPU_COMFORT`
(default 50) for a few samples, it eases back toward
`COMSTAR_AVATAR_BLOOM_MAX` / `COMSTAR_AVATAR_FPS_MAX`. Manual `/control/avatar`
pauses auto-adapt for 60 s and becomes the new recovery ceiling.
Disable with `COMSTAR_AVATAR_ADAPT=0`.

See `docs/adr/0004-terminal-control.md`.

### Tunnelled Google Workspace (off-the-shelf MCP)

**No custom Gmail/Calendar/Drive MCP in this repo.** Comstar pairs OAuth once
(device code + QR), stores a per-userid refresh token (`0600`), starts a pinned
npm package via `LocalMcpHost.startNpxPackage`, and registers it on the Reach
session overlay as `client.google_workspace` (`tunnel://session-mcp/google_workspace`).

| piece | location |
|---|---|
| Overlay root | `overlays/comstar/` (AO-shaped catalogs) |
| Agents | `agent_providers/*.yaml` → Reach `OverlayPacker` |
| Skills | `agent_skills/*.yaml` → packer (`client.*` + backstory inject) |
| Platform harness profiles | `agent_harnesses/` (`harness_profile:` on agents) |
| User harness packs | `harnesses/<pack>/` (scenarios for live E2E) |
| MCP definition | `mcp_providers/google_workspace.yaml` (tunnel bootstrap) |
| Agent allowlist | `voice_responder.yaml` → `client.google_workspace` + skills |
| Bootstrap | `ComstarMcpBootstrap` reads overlay MCP YAML → `extraMcps` |
| Tokens | `~/.local/share/comstar/google/<userid>.json` (or `COMSTAR_DATA_DIR`) |
| Client secrets | env `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` (never commit) |

See `overlays/comstar/README.md`. Guests never get Google MCP ids and cannot start
pairing. Missing/revoked tokens soft-skip the MCP; voice still works. AO disk
`config/mcp_providers/` is **not** used for this path — session-overlay only.
**No AO daemon catalog merge** for COMSTAR skills/MCP; Reach registers them on the
session.
After TV device pairing succeeds, the bridge may email a **Desktop OAuth**
upgrade link (SMTP) to the Google account email so Gmail / full Drive can be
granted. Env: `COMSTAR_SMTP_*`, `GOOGLE_DESKTOP_CLIENT_ID` /
`GOOGLE_DESKTOP_CLIENT_SECRET`, `COMSTAR_OAUTH_REDIRECT_BASE`, optional
`COMSTAR_OAUTH_BIND_LAN=1`. Callback listens on port **8781**. Token JSON may
include `"client":"tv"|"desktop"` so MCP refresh uses the matching client
secrets.
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
| `attention.timezone` | optional spoken TZ label (IANA or human); clock uses Pi system time |
| `attention.idle_sleep_seconds` | 0–86400; `0` disables; silent auto-sleep after idle (default 600) |
| `avatar.render` | enum: local \| streamed |
| `directory.enabled` | bool |
| `directory.sidecar_url` | non-empty when `enabled` |
| `directory.require` | bool — fail closed when true |
| `directory.cache_ttl_seconds` | 60 ≤ x ≤ 3600 |
| `directory.timeout_ms` | 200 ≤ x ≤ 10000 |
| `presence.ha_person_by_uid` | map of COMSTAR uid → HA `person.*` entity_id (optional) |
| `audio.duplex` | enum: `half` \| `full` (`full` requires AEC — ADR 0007) |

---

## 7b. House presence snapshot (Phase 2)

**Transport:** bridge Admin HTTP (`:8781`), unauthenticated read like `/health`
(LAN trust model same as heal probes; do not expose beyond the Pi LAN).

```
GET /v1/presence/home
```

Response:

```json
{
  "ts": 1722892800000,
  "people": [
    {
      "uid": "zlatko",
      "displayName": "Zlatko",
      "ha_entity": "person.zlatko_lakisic",
      "state": "home"
    }
  ]
}
```

| field | meaning |
|---|---|
| `ts` | epoch ms when the snapshot was built |
| `uid` | COMSTAR / IPA uid from `presence.ha_person_by_uid` |
| `displayName` | HA friendly_name when present, else uid |
| `ha_entity` | configured entity_id |
| `state` | HA person state (`home`, `not_home`, zone name, or `unknown` on error) |

**Non-goal:** this API does **not** drive the attention FSM or open AO sessions
(ADR 0006). Local camera identity remains the terminal identity terminator.

Optional voice path: bridge-local `HomeDataIntent` → spoken summary without AO.

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
| `FaceRecognized(userid, confidence, displayName?)` | vision poll + directory resolve (`userid` = IPA uid) |
| `FaceUnknown` | vision poll, or directory miss when `require: true` |
| `PresenceSet(people, primaryUserid?)` | multi-face presence (Phase 2); singular `FaceRecognized` kept for compat |
| `PresencePrimaryChanged(from, to)` | primary addressable userid switched |
| `WakeWord(score)` | audio proc |
| `SpeechStart` / `SpeechEnd(durationMs)` | audio proc |
| `TranscriptReady(text)` | bridge STT call |
| `ResponseReady(text, audio)` | bridge AO + TTS |
| `PlaybackEnded` | kiosk |
| `Tick` | injected clock, 10 Hz |
| `Error(scope)` | any |
| `EnterSleep` | terminal MCP `sleep_enter` / control HTTP |

### Terminal presence set (Phase 2)

While engaged, vision may keep recognizing at a reduced rate. The machine tracks
`Map<userid, PresenceEntry>` with per-person TTL.

| policy | rule |
|---|---|
| Primary | highest face confidence among non-expired entries (gaze bias later) |
| Guest co-presence | guests may appear in the set; memory/turns bind only to addressable (non-guest) primary |
| Primary change | close/open AO session + greeter debounce; never merge guest↔known memory |
| Compat | `FaceRecognized` still updates the primary cache when only one face is tracked |

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
| ambient / noticed / engaged | Tick | idle_sleep_seconds > 0 AND no interaction for that long | sleeping | silent `EnterSleep` (no sleep-ack TTS) |
| listening | SpeechEnd | — | listening | finalize capture, call STT |
| listening | Tick | elapsed > max_utterance_seconds | responding | force-close capture with what we have |
| listening | TranscriptReady | text non-empty | responding | `thinking` on, call `directAgent` |
| listening | TranscriptReady | text empty | engaged | play `error` tone, `listen.stop` |
| responding | ResponseReady | — | responding | `speak` to kiosk |
| responding | PlaybackEnded | — | engaged | open follow-up window, re-enable wake |
| responding | Tick | elapsed > orchestration timeout | engaged | speak fallback line, re-enable wake |
| any (not sleeping) | EnterSleep | — | sleeping | stop listen, cancel follow-up, wake armed, ignore vision |
| sleeping | WakeWord | score ≥ threshold, wake-only utterance | listening (or engaged+follow-up) | `listen.start` (keep session if open) |
| sleeping | WakeWord | score ≥ threshold, same utterance has residual prompt | responding | run residual via `directAgent` (no sleep-wake greeting) |
| sleeping | PersonDetected / Face* / Speech* | — | sleeping | ignored |
| any | Error(fatal) | — | ambient | tear down session, log, re-arm |

### Invariants (asserted in tests, and at runtime in debug builds)

1. An AO session exists **iff** state ∈ {engaged, listening, responding}
   (session may remain open while `sleeping` until TTL/absent teardown on wake path).
2. Wake word is armed **iff** state ∉ {listening} and not (half-duplex and playing),
   **or** state is `sleeping` (always armed). When `audio.duplex == full`, wake may
   stay armed during `playing` (barge-in); AEC required (ADR 0007).
3. At most one in-flight `directAgent` call at any time.
4. `turn_id` is non-null **iff** state ∈ {listening, responding}.
5. Identity cache TTL is refreshed only by a positive `FaceRecognized`, never by
   `PersonDetected` alone.
6. No transition takes longer than 50 ms of wall clock inside the state machine
   itself — all I/O is dispatched, never awaited, inside a transition.
7. In `sleeping`, vision and VAD events are no-ops; only `WakeWord` exits.
8. Memory attribution uses the **primary addressable** userid only; guest co-presence
   must not write into a known user's store.

### Full duplex barge-in (Phase 2)

When `audio.duplex == full` and AEC is healthy:

| from | event | to | side effects |
|---|---|---|---|
| responding (playing) | WakeWord / SpeechStart | listening | `speak.cancel`, cancel in-flight turn, `listen.start` |

Default remains `half` until soak proves false-barge rate. If AEC init fails,
force `half` and log `aec_unavailable`.

---

## 9. Kiosk avatar (TalkingHead)

**Status:** VERIFIED (audio path) 2026-08-02 — GLB lip-sync still SPEC.
**Phase 2 mood:** SPEC — `speak.mood` / sentiment → SVG emblem gesture.

### Phase 1 audio path (shipping)

Kiosk `terminal/kiosk/avatar.js` plays `speak.audioUrl` with `HTMLAudioElement`.

| Event | When |
|---|---|
| `speak.started` | Immediately before `audio.play()` (or 1.2 s timer if `audioUrl` empty) |
| `speak.ended` | `audio.onended` / `onerror` / cancel |
| `ready` | On WS open — `{avatarLoaded, webglVendor, fps}` |

`#avatar` is a full-bleed mount. Without a GLB, the HUD + ambient gradient render;
spoken conversation still works (ADR 0001 kiosk sink).

### Mood / sentiment (Phase 2)

| channel | values | meaning |
|---|---|---|
| `speak.mood` | `neutral` \| `happy` \| `concerned` \| `thinking` \| `celebratory` | Reply affect for emblem params |
| `config.mood` | same enum | Initial / idle mood on kiosk connect |
| `avatar.options` | may include `mood` | Live mood without a speak |

Bridge derives mood from a LAN-local heuristic (or AO-side tag) on reply text —
never phone-home sentiment APIs. SVG emblem maps mood → spin / bloom / meter
presets; TalkingHead GLB remains optional (`avatar.render`).

### TalkingHead GLB path (next)

When `avatar.model` (`.glb`) is present and WebGL is healthy:

1. Load TalkingHead (or equivalent) into `#avatar`.
2. Drive lip-sync from the same `audioUrl` (or attached MediaElement source).
3. On WebGL context loss: fall back to HTMLAudioElement; keep `speak.*` events.
4. Bridge hang guard: if `speak.ended` missing after `tts_total + 5s`, force
   `PlaybackEnded`.

Pi fps / render-path ADR: `docs/adr/0002-render-path.md`.
