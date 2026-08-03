# DEV_LOOP — developing on the Mac, running on the Pi

Three machines on one LAN:

```
  MacBook (dev)              Raspberry Pi 4 (terminal)         AI server (RTX 4000 Ada)
  ├ Cursor / editor          ├ camera, mic, speaker, screen    ├ agentic-orchestration
  ├ bridge (dev mode)   ◄──► ├ comstar-audio                   ├ CodeProject.AI :32168
  ├ kiosk / Chrome      ◄──► ├ Chromium kiosk                  ├ speech sidecars :8090/91
  ├ local STT/TTS (:8090/91) ├ optional comstar-stt/tts        └ (AO hello.speech)
  └ test runners             └ comstar-bridge (prod)
     comstar-dev.lan            comstar.lan                       ai-server.lan
```

The goal is a loop where **you never stand up.** Standing in front of a camera 200
times to test a state transition is how projects die.

---

## 0. Names and keys (do this once)

`/etc/hosts` on the Mac, or better, mDNS — the Pi advertises `comstar.local` by
default via Avahi. Pin real names anyway so scripts don't depend on discovery:

```
192.168.1.40   comstar.lan comstar
192.168.1.20   ai-server.lan ai-server
```

`~/.ssh/config` on the Mac:

```
Host comstar
  HostName comstar.lan
  User zlatko
  IdentityFile ~/.ssh/id_comstar
  ControlMaster auto
  ControlPath ~/.ssh/cm-%r@%h:%p
  ControlPersist 10m
  # tunnels for remote debugging, always available
  LocalForward 9222 127.0.0.1:9222   # Chromium DevTools
  LocalForward 8181 127.0.0.1:8181   # Dart VM service
  LocalForward 5678 127.0.0.1:5678   # Python debugpy
  LocalForward 8779 127.0.0.1:8779   # COMSTAR dev console
```

`ControlPersist` is not cosmetic — every `make` target below opens an SSH
connection, and without multiplexing you pay a full handshake each time. With it,
`ssh comstar true` takes ~15 ms.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_comstar
ssh-copy-id -i ~/.ssh/id_comstar comstar
ssh comstar true    # must not prompt
```

---

## 1. The four loops, fastest first

Different parts of the system have very different iteration costs. Use the right
loop for what you're changing.

| Changing | Loop | Turnaround |
|---|---|---|
| Avatar / kiosk JS | Mac Chrome → Mac kiosk-dev | **instant, hot reload** |
| Bridge / state machine | Bridge on Mac in dev mode | **~2 s, with breakpoints** |
| Full Mac voice bring-up | Bridge + STT/TTS + Chrome on Mac | **seconds** (see Loop B+) |
| Audio / wake word on Pi | Must run on the Pi; sync + restart | ~8 s |
| Anything, final check | Full deploy to the Pi | ~40 s |

### Loop A — kiosk (instant)

The kiosk is a web page. Serve it from the Mac with live reload and point the Pi's
Chromium at the Mac's URL instead of a local file.

```bash
# Mac
make kiosk-dev          # vite/live-server on :5173, watches terminal/kiosk/
```

```bash
# Pi, one-time: change the kiosk unit's ExecStart to
chromium-browser --kiosk --remote-debugging-port=9222 \
  http://comstar-dev.lan:5173/?bridge=ws://comstar-dev.lan:8777
```

Now editing `avatar.js` on the Mac reloads the Pi's screen in under a second. You
develop lip-sync while watching the actual panel, from your desk.

**Also open the same URL in Chrome on the Mac.** Two kiosk clients, one bridge —
both render the same avatar. You iterate at 120 fps on the Mac and glance at the Pi
only to confirm it still holds 24 fps there.

### Loop B — bridge on the Mac (the big one)

The bridge is pure network I/O: it talks to CPAI and AO over HTTP/WS, and to audio
and kiosk over WS. **Nothing about it requires the Pi.** So during development, run
it on the Mac and let the Pi's audio and kiosk processes connect to it.

```bash
# Mac
make bridge-dev         # dart run --observe, binds LAN, loads config/comstar.dev.yaml
```

```bash
# Pi
sudo systemctl stop comstar-bridge
COMSTAR_BRIDGE=ws://comstar-dev.lan:8778 systemctl --user restart comstar-audio
```

You now have: full Dart debugger, breakpoints, hot reload, and the state machine
running in your editor — while a real camera, real mic and real speaker feed it.
This is the difference between a two-second edit cycle and a forty-second one, on
the file you'll edit most.

> **Security gate.** Dev mode binds the local WS to the LAN instead of `127.0.0.1`,
> which the privacy model forbids in production. It is gated three ways: it requires
> `COMSTAR_ENV=dev`, it requires `dev.lan_token` to match on every connection, and
> the bridge refuses to start in dev mode if `dev.bind_lan` is true in a config file
> named `comstar.yaml` rather than `comstar.dev.yaml`. A T0 test asserts
> `comstar.example.yaml` has `dev.bind_lan: false`. Do not weaken any of these.

### Loop B+ — Mac browser voice (no Pi)

For STT/TTS and kiosk bring-up without standing at the terminal:

```bash
cp config/comstar.mac.env.example config/comstar.mac.env   # once; gitignored
set -a && source config/comstar.mac.env && set +a

make stt-dev                                            # :8090 faster-whisper
COMSTAR_ENV=dev make bridge-dev                         # bind_lan: false in comstar.dev.yaml
make kiosk-dev
# Chrome → http://127.0.0.1:5173/?bridge=ws://127.0.0.1:8777/kiosk
```

Device env: `COMSTAR_CAMERA_SOURCE` / `COMSTAR_MIC_SOURCE` / `COMSTAR_SPEAKER_SOURCE`
(see RUNBOOK). The kiosk has **no camera preview** — the bridge owns the camera via
ffmpeg. Score STT on live bridge captures, not only golden WAVs (`testdata/stt/`).

### Loop C — audio (needs the Pi)

The mic is on the Pi, so this one has to deploy. Keep it fast with rsync over the
persistent SSH connection:

```bash
make audio-sync         # rsync terminal/audio/ + restart the unit, ~8 s
```

For wake-word threshold work, don't deploy at all — that's an **offline** loop
against recorded audio:

```bash
make wake-sweep FILE=fixtures/room_60min.wav   # runs entirely on the Mac
```

### Loop D — full deploy

```bash
make deploy             # build bridge for arm64, rsync all three, restart, tail logs
```

---

## 2. The dev console — stop walking into frame

The single highest-leverage tool in this document. The bridge serves a control panel
on `:8779` (dev mode only). Open it on the Mac next to your editor.

**Left pane — live state:**
- Current attention state, with the ladder drawn and the active rung lit
- Current identity, confidence, votes accumulated, TTL remaining
- Live camera thumbnail with the YOLO box drawn on it
- Mic level meter and last wake score
- Last 20 transitions with timestamps
- Latency spans for the last 5 turns, as stacked bars

**Right pane — event injection.** Buttons that push synthetic events straight into
the state machine, bypassing hardware:

| Button | Injects |
|---|---|
| Person enters / leaves | `PersonDetected(0.9)` / `PersonAbsent` |
| Recognise as… *(dropdown of enrolled userids)* | `FaceRecognized(userid, 0.87)` |
| Unknown face | `FaceUnknown` |
| Fire wake word | `WakeWord(0.8)` |
| Speak… *(text box)* | `TranscriptReady(text)` — skips mic and STT entirely |
| Playback ended | `PlaybackEnded` |
| Force timeout | orchestration timeout path |
| Kill CPAI / AO / STT | flips the corresponding client into failure mode |

The text box is the one you'll use most: type a question, hit enter, and the full
orchestration → TTS → avatar path runs with no speaking and no walking. Testing
twenty phrasings takes a minute instead of ten.

**Bottom — the log tail**, filtered by `evt` prefix, with `turn_id` clickable to
isolate one turn.

Event injection routes through the *same* `handle(Event)` entry point as real
hardware, so nothing is bypassed except the sensors. Injected events are tagged
`src: "injected"` in the logs so you can never mistake a synthetic run for a real
one.

---

## 3. Remote debugging

All three tunnels are already open from the `~/.ssh/config` above.

**Chromium on the Pi, from the Mac.** Open `chrome://inspect` on the Mac, add
`localhost:9222` as a discovery target. The Pi's kiosk page appears; click inspect
and you get full DevTools — console, network, profiler, WebGL frame timing — on the
device's actual page. This is how you diagnose "the avatar stutters on the Pi"
without guessing.

**Dart VM service.** `make bridge-pi-debug` starts the bridge on the Pi with
`--enable-vm-service=8181`. Open the printed DevTools URL on the Mac. Use this only
when you need to debug the bridge *on the Pi specifically* — Loop B is better for
everything else.

**Python.** `make audio-debug` starts `comstar-audio` under
`debugpy --listen 127.0.0.1:5678 --wait-for-client`. Attach from Cursor with a
standard `attach` launch config on `localhost:5678`.

**Pi screen, if you need the real framebuffer.** `wayvnc` on the Pi, any VNC client
on the Mac. Rarely needed — the kiosk is a web page, so opening the same URL locally
is faster and more accurate for everything except full-screen and font rendering.

---

## 4. Logs

One command, all three processes, merged and coloured, from the Mac:

```bash
make logs                    # everything
make logs F=attention        # only evt starting with "attention."
make logs TURN=t_01J8XYZ     # one turn, all processes
```

Implemented as:

```bash
ssh comstar 'journalctl -f -o cat \
  -u comstar-bridge -u comstar-audio -u comstar-kiosk' \
  | jq -c --unbuffered 'select(.evt | startswith($f))' --arg f "${F:-}" \
  | scripts/colorlog.py
```

`colorlog.py` colours by `proc`, dims `debug`, bolds `error`, and renders `span`
events as a right-aligned duration so slow stages stand out visually while scrolling.

**Pull a window for offline analysis:**

```bash
make logs-export SINCE="1 hour ago" > /tmp/run.jsonl
python scripts/latency_report.py /tmp/run.jsonl
```

---

## 5. Running tests from the Mac

```bash
make test          # T0-T2, entirely local, no Pi, no network        ~3 min
make test-integ    # T3, hits the real AI server from the Mac        ~10 min
make test-hw       # T4, runs ON the Pi via ssh, streams results back ~20 min
make soak          # T5, starts on the Pi, detaches, collects for 24h
```

`make test-hw` is the interesting one. It runs the hardware suite remotely and
brings the results home:

```bash
ssh comstar 'cd /opt/comstar && COMSTAR_TEST_HW=1 dart test -t hw --reporter json' \
  | tee artifacts/hw-$(date +%s).json \
  | dart run tool/pretty_test.dart
```

T3 runs **from the Mac**, not the Pi, deliberately: the Mac is a third machine
hitting the same LAN services, which catches host-specific assumptions (a hardcoded
`localhost`, a path that only exists on the Pi) that a Pi-local test would miss.

---

## 6. Fake hardware — develop with the Pi switched off

Everything except the mic and camera works on the Mac alone.

```bash
make dev-full       # bridge + fake camera + fake mic + fake kiosk, all local
```

- **Fake camera** replays a recorded video file frame by frame through the same
  `camera.dart` interface. Record a 2-minute clip of yourself walking in and out of
  frame once, and reuse it forever — it makes vision behaviour *reproducible*, which
  a real camera never is.
- **Fake mic** feeds WAV files at wall-clock rate through the audio pipeline's
  interface, so wake word and VAD run for real against known input.
- **Fake kiosk** is a headless client that acknowledges `speak` with correctly
  timed `speak.started` / `speak.ended`.

Point these at the *real* AI server and you have a complete system on the Mac with
correct latency characteristics for everything except capture.

---

## 7. Preflight

```bash
make doctor
```

Checks, and prints a pass/fail table:

| Check |
|---|
| SSH to `comstar` without a prompt, under 100 ms |
| Pi disk free > 2 GB, temp < 70 °C, no throttling flag set |
| Dart, Python, Chromium versions on the Pi match `.tool-versions` |
| `ai-server.lan:32168` reachable; both CPAI modules present **and on CUDA** |
| AO daemon reachable, version ≥ v1.27.0, both `AGENTIC_SERVE_*` flags set |
| faster-whisper on Pi (`:8090`) or Mac `make stt-dev` |
| Piper/sherpa TTS on Pi (`:8091`) |
| Camera and mic enumerate on the Pi |
| Ports 8777/8778/8779 free or held by the expected process |
| Clock skew between Mac and Pi < 1 s *(latency spans are meaningless otherwise)* |

Run this first whenever something is behaving strangely. Most "the bridge is broken"
sessions are actually a CPAI module that silently fell back to CPU, or NTP drift
making the span numbers nonsense.

---

## 8. Makefile targets, complete list

```
make doctor          preflight checks
make dev-full        everything on the Mac with fake hardware
make bridge-dev      bridge on the Mac, LAN-bound, Pi peripherals connect in
make kiosk-dev       kiosk dev server with hot reload
make audio-sync      rsync + restart audio on the Pi
make stt-dev         local faster-whisper STT (:8090)
make deploy          full build + deploy + restart all units
make rollback        redeploy the previous release symlink
make logs            merged coloured tail        [F=prefix] [TURN=id]
make logs-export     dump a window as jsonl      [SINCE="..."]
make console         open the dev console in a browser
make test            T0-T2 local
make test-integ      T3 against real services
make test-hw         T4 on the Pi, results streamed back
make soak            T5, detached
make wake-sweep      offline threshold ROC       [FILE=...]
make latency         latency report from the last hour
make enroll          capture from the Pi camera and register a face
make pi-shell        ssh comstar with the right cwd
```

---

## 9. Deploy layout on the Pi

Symlinked releases so rollback is instant:

```
/opt/comstar/
├── releases/
│   ├── 20260802-191244/
│   └── 20260802-203301/
├── current -> releases/20260802-203301
├── config/comstar.yaml        # not in the repo, not overwritten by deploy
└── models/                    # wake word onnx, avatar glb — not in the repo
```

`make deploy` builds, rsyncs to a new timestamped release, flips `current`, restarts
the three units, waits for all three to report healthy, and **automatically rolls
back if any unit fails to come up within 30 s.** A bad deploy to a headless device in
another room should not require you to go and get a keyboard.

---

## 10. Where this fits in the plan

Build the loop during **M1**, alongside the skeleton — it is task M1.7. Build the dev
console during **M3**, when the state machine exists and event injection becomes
meaningful (task M3.7). Both pay for themselves inside a single milestone.

Fake camera and fake mic are already required as T2 mocks, so §6 costs almost
nothing extra: wire the existing fakes to a runnable entry point.
