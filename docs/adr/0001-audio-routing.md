# ADR 0001 — Audio routing (TTS playback sink)

**Status:** Accepted  
**Date:** 2026-08-02  
**Milestone:** M0.6

## Context

CONTRACTS §6 asked whether TTS audio should play in:

- **(a)** the kiosk (Chromium), keeping lip-sync on one clock, or  
- **(b)** the audio process via ALSA, lower latency but separate timing to the avatar.

The Pi has HDMI + headphones sinks and a working Chromium/labwc session. TalkingHead requires audio + visemes aligned in the browser for reliable lip-sync.

## Decision

Choose **(a) — kiosk is the audio sink.**

- Bridge sends `speak` with `audioUrl` (loopback HTTP) to the kiosk.  
- Kiosk plays audio and emits `speak.started` / `speak.ended`.  
- Follow-up window opens on `speak.ended` from the kiosk.  
- Bridge → audio `play` message is **not** used in Phase 1.

## Consequences

- Accept ~100 ms extra latency vs raw ALSA for guaranteed sync.  
- If Chromium audio on the Pi proves unreliable in M7 UAT, revisit and write a superseding ADR.  
- CONTRACTS §2 `play` remains documented as unused/reserved until then (or removed from active tables in a follow-up CONTRACTS edit).
