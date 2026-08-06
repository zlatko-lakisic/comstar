# ADR 0007 — Full-duplex barge-in and acoustic echo cancellation

**Status:** Accepted  
**Date:** 2026-08-05  
**Milestone:** Phase 2 (P2.5)

## Context

Phase 1 ships `audio.duplex: half`: wake and VAD are disabled while TTS plays
so HDMI echo does not look like user speech. Users cannot interrupt mid-reply.
Config already documents that `full` requires AEC.

Shared enclosure (USB mic + HDMI/speaker) has no clean hardware reference
channel by default. Software AEC needs a reference of what is playing.

## Decision

1. **Default remains `half`** until hallway soak shows acceptable false-barge
   rates with AEC enabled.
2. **Reference channel:** capture a loopback / monitor of the playback sink
   (PipeWire/Pulse monitor source of the COMSTAR speaker sink) alongside the
   mic. Feed both into a software AEC (prefer WebRTC AEC3 or SpeexDSP) in the
   audio process before VAD/wake.
3. **When `duplex: full`:** attention allows `WakeWord` / `SpeechStart` while
   `playing`; coordinator issues `speak.cancel` on barge-in and tears down the
   in-flight reply turn per CONTRACTS.
4. **Fallback:** if AEC init fails, force `half` and log `aec_unavailable`.
5. **Out of scope for first ship:** multi-mic beamforming, neural AEC.

## Consequences

- Audio capture pipeline becomes stereo-ish (mic + reference) or dual-stream.
- Invariants for wake-armed change when duplex is full.
- RUNBOOK must document PipeWire monitor source setup on the Pi.
