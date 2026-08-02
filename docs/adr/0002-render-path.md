# ADR 0002 — Avatar render path

**Status:** Accepted (interim) — 2026-08-02  
**Context:** M7 must choose local WebGL vs streamed frames for the kiosk avatar.

## Decision

**Ship local HTMLAudioElement playback now; keep local WebGL TalkingHead as the
target when a GLB is available.** Do not stream rendered frames from the AI server
in Phase 1.

## Rationale

- Audio sink is already the kiosk (ADR 0001); lip-sync and audio must share one clock.
- Streaming video of an avatar adds LAN bandwidth and another failure mode without
  helping the walk-up demo before a GLB exists.
- Pi 4B + Chromium can play WAV/HTTP audio reliably at 1024×768; WebGL fps for a
  full TalkingHead GLB is still to be measured on this board and recorded here.

## Consequences

- `terminal/kiosk/avatar.js` uses `HTMLAudioElement` until `assets/comstar.glb` (or
  `avatar.model`) is present.
- CONTRACTS §9 documents both paths; lip-sync acceptance remains an open UAT.
- Revisit if Pi WebGL fps &lt; 24 sustained with the chosen GLB — then consider a
  lighter mesh or baked viseme sprites, not server-side streaming.

## Measurement TODO

On `comstar-ai`, load the GLB in Chromium kiosk and record avg/1% fps for 60 s idle
+ 10 spoken lines. Paste results into `docs/BASELINES.md` when available.
