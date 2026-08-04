# terminal/kiosk

The avatar renderer. Chromium in kiosk mode on the Pi, driven entirely by
bridge messages over the local WebSocket (`docs/CONTRACTS.md` §1).

This is the **2D renderer**: the ComStar starburst as live inline SVG on a dark
field. No background image, no WebGL, no GLB, no blend shapes, no `three`
dependency, and nothing fetched from the internet. The mark is the avatar.

```
kiosk/
├── index.html          production entry point
├── debug.html          standalone harness, no bridge required
├── avatar.js           the renderer
├── presets.js          swappable emblem designs
└── bridge_client.js    envelope + reconnect
```

No assets directory. Everything is generated in code.

## Run it

```bash
cd terminal/kiosk
python3 -m http.server 5173
```

Open `http://localhost:5173/debug.html`. Must be served over HTTP; opening the
file directly fails on ES module CORS.

You get all five states, live sliders for emblem scale and bloom, a gaze slider
(and auto-sweep), and a mic-level slider that can also wire to the real
microphone. Changes apply immediately via `avatar.setOptions` — no reload.

On the Pi, push the same knobs without restarting Chromium:

```bash
# from the Pi (or SSH tunnel to 8776)
curl -sS -X POST http://127.0.0.1:8776/control/avatar \
  -H 'content-type: application/json' \
  -d '{"bloom":3,"fps":12,"scale":0.62}'
curl -sS http://127.0.0.1:8776/control/avatar
```

Bridge pushes `avatar.options` to the kiosk over WS.

## Sizing it on the real panel

Two values must be set by eye against the actual screen. Both are live in
`debug.html`, via `POST /control/avatar` on the Pi, and as query parameters
(`?scale=` and `?bloom=`) for cold start.
| Option | Default | What goes wrong |
|---|---|---|
| `emblemScale` | `0.62` | Too high and the star points run off the edges. Portrait panels need a lower value than you expect, because the emblem is sized by the short axis but the points extend along the long one. |
| `bloom` | `9` | Too high and the halo swamps the sharp core into a white mass. Measured in SVG **user units**, not CSS pixels, so it is invariant to panel size. Set `0` to disable. |

> The bloom is an SVG `feGaussianBlur`, deliberately not a CSS `filter: blur()`.
> CSS blur is measured in screen pixels and applied *after* the viewBox scale,
> so the same number blows out on a large panel and disappears on a small one.
> This bit us once already.

## How it animates

| Channel | Driven by |
|---|---|
| Ring rotation, brightness, scale | attention state, damped over ~300ms |
| Halo swell and meter arc | `listening` message `level` |
| Core pulse | speech amplitude from an `AnalyserNode` on the audio element |
| Emblem drift | `setGazeFromBox()` with the CPAI face bounding box |
| Counter-rotation | `thinking` message |

Amplitude is read from the waveform actually being played, so it **cannot
drift**. This is why `speak` no longer needs a `visemes` field; delete it from
CONTRACTS §1 when you wire the bridge.

## Emblem presets

Five ship in `presets.js`. Pick one with the `emblem` option, or `?emblem=` in
the debug harness.

| Preset | Character |
|---|---|
| `starburst` | The ComStar mark. The project's identity, and the default. |
| `reactor` | Hexagonal containment rings around a faceted core. Industrial. |
| `sentinel` | A vertical sensor slit between bracket arcs. Watchful, minimal. |
| `spectrum` | Radial waveform. Most reactive to speech, least symbolic. |
| `instrument` | Navigational dial with tick marks. Precise and quiet. |

A preset is SVG markup centred on the origin in a 512x512 viewBox. Two optional
hooks give it extra behaviour:

- a `.cs-rings` group counter-rotates against its halo copy, and spins faster
  while `thinking` is set
- every `<rect>` inside a `.cs-bars` group is treated as a spectrum bar and
  driven by speech amplitude with a per-bar phase offset

Neither is required. Add your own by appending to `EMBLEMS`, or pass raw markup
to the `emblem` option to skip the registry entirely.

**Which to pick.** `starburst` if the device should feel like *your* project;
`spectrum` if you want the strongest read on whether it is currently speaking,
since forty bars carry an envelope far better than one pulsing shape;
`sentinel` if you want it to feel like it is watching, which is either the point
or exactly what you want to avoid in a living room.

## Tuning

Everything worth adjusting lives in the `STATE_PARAMS` table at the top of
`avatar.js`. Set these by eye against the real panel during M7.3, not from the
numbers here. The one most likely to be wrong is `ambient.spin`: too slow reads
as frozen, too fast is distracting in your peripheral vision every evening.

To reskin, replace the `EMBLEM` template string. Nothing else changes as long
as the new markup keeps a `.cs-rings` group.

## Performance notes

- The halo uses a CSS `blur()` filter as a cheap stand-in for bloom. If the Pi
  struggles, pass `{ blur: false }` and the emblem stays sharp with no halo
  softening.
- Only `transform` and `opacity` are touched per frame, so the compositor does
  the work rather than the layout engine.
- This should sit near the panel refresh rate on a Pi 4. If it does not,
  something else is wrong; do not reach for the streamed render path over a 2D
  scene.

## Query parameters

| param | effect |
|---|---|
| `?bridge=ws://host:8777` | override the bridge URL, defaults to `127.0.0.1` |
| `?demo` | on-screen state, fps, gaze and amplitude readout (M8.6 demo mode) |

Dev loop (`docs/DEV_LOOP.md` §1, Loop A):

```
chromium-browser --kiosk --remote-debugging-port=9222 \
  'http://comstar-dev.lan:5173/?bridge=ws://comstar-dev.lan:8777'
```

## If you later want the 3D head

The WebGL renderer exposes an identical public API (`setState`, `setGaze`,
`setGazeFromBox`, `setMicLevel`, `setThinking`, `speak`, `cancelSpeak`,
`stats`, `dispose`), so it is a file swap. Keep this one as the fallback
either way.
