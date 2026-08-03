# ADR 0003 — Speech compute on Ada via Reach

**Status:** Accepted  
**Date:** 2026-08-03  
**Milestone:** M6 (voice path)

## Context

Phase 1 originally kept STT/TTS on the Pi (`comstar-stt` / `comstar-tts`) so the
voice path did not depend on LAN bandwidth and PCM never left the box until a
transcript reached AO. AO **v1.28** and Reach **v0.2** now advertise OpenAI-compatible
speech sidecars on WebSocket `hello.speech`, discovered as
`SessionBridge.speechClient` (`transcribe` / `synthesize` over HTTP — not the
planner WebSocket).

The Pi is already a thin I/O terminal for vision (frames → CPAI). Moving speech
**compute** to the Ada host matches that split while capture, VAD, wake, playback,
and the kiosk stay on the Pi.

## Decision

1. **Prefer Reach speech** after `SessionBridge.start` when `speechClient != null`.
2. **Fall back** to `COMSTAR_STT_URL` / `COMSTAR_TTS_URL` (local Pi units or Mac
   bring-up) when speech is absent, disabled, or the session is not open.
3. **Do not** route utterance turns through AO MCP/planner solely for STT, and
   **do not** ferry PCM on the Reach session WebSocket.
4. Optional `ReachConnectionConfig.speechToken` from `COMSTAR_SPEECH_TOKEN` /
   `AGENTIC_SPEECH_TOKEN` when Ada sets a sidecar bearer.
5. Overlay / `direct_agent` must keep working with `speechClient == null`.

## Consequences

- PCM for utterances leaves the Pi over LAN to Ada-advertised STT/TTS URLs — same
  trust boundary as CPAI and AO (LAN-only, Phase 1). Privacy docs and RUNBOOK
  reflect this deliberately.
- Production can stop requiring always-on `comstar-stt` / `comstar-tts` once Ada
  speech is proven; keep those units (and env URL overrides) for Mac/dev and
  offline fallback.
- Re-bench live bridge fixtures (`mic → audio → bridge → remote STT`) against the
  <15s / ideally <6s turn budget; GPU STT on Ada should usually beat Pi CPU
  `tiny`, but LAN transfer is a new variable.
- Requires AO ≥ 1.28 with `AGENTIC_SPEECH_ENABLED=1` and advertised sidecar URLs;
  older AO leaves `speechClient == null` and the env fallback path unchanged.
