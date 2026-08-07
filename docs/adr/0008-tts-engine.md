# ADR 0008 — TTS engine: Kokoro on Ada, Piper fallback on Pi

**Status:** Proposed (TTS.0 partially verified)  
**Date:** 2026-08-07  
**Milestone:** M6 / TTS.0–TTS.8  
**Supersedes (partially):** latency assumption in ADR 0003 that local Piper is
the quality/latency default for spoken answers.

## Context

Hallway listening makes Piper (`en_US-ryan-high`) feel synthetic. Kokoro
(sherpa-onnx `OfflineTtsKokoroModelConfig`) is the intended Tier-1 voice on the
AI server; Piper remains on-Pi Tier-2; baked Kokoro WAVs are Tier-0. Full
handoff: `docs/TTS_HANDOFF.md`.

## Decision (in progress)

1. **Primary live TTS:** Kokoro on the AI server over the existing OpenAI-compatible
   `POST /v1/audio/speech` contract.
2. **Fallback:** Pi Piper (`comstar-tts-local`) with turn-boundary failover only
   (no mid-utterance engine splice).
3. **Greetings / fixed lines:** bake with Kokoro at build time (Tier 0).
4. **Streaming:** design for **sentence-level chunking** in the server if product
   needs first-audio &lt; full synth — see Consequences.

## TTS.0 verification status

| Item | Status | Evidence |
|---|---|---|
| TTS.0.1 RTF idle + CPAI contended | **Done (CPU)** | `docs/BASELINES.md` §12; fixture `docs/fixtures/kokoro_bench_*.json` |
| TTS.0.1 CUDA EP | **Blocked** | Ada `venv-tts` ORT has no CUDA; falls back to CPU |
| TTS.0.2 streaming API | **Done** | Python `generate(..., callback=)` documented; C callback exists |
| TTS.0.2 Kokoro incremental chunks | **No** — single full-buffer callback | BASELINES §12; TTFC ≈ synth_sec |
| TTS.0.3 voice pick on Pi speakers | **Open** | Candidate default `af_heart` (sid 0); must listen in room |
| TTS.0.4 sample rate | **Tentative 24 kHz** | Kokoro reports 24000; Piper 22050 — CONTRACTS §2 pending |

### Measured (CPU Kokoro, sid 0, 2026-08-07)

| mode | RTF p50 | TTFC ms p50 | multi-callback |
|---|---:|---:|---|
| idle | ~1.07 | ~1464 | no |
| contended (CPAI storm) | ~0.96 | ~1336 | no |

Contended did not hurt Kokoro (CPU-bound); GPU VRAM stayed ~15.7 GiB (CPAI).

## Consequences

- Hand-off latency budget (~150 ms first chunk on GPU) is **not** validated until
  a GPU-enabled sherpa-onnx build exists. On CPU, first audio ≈ full utterance
  (~1.1–2.0 s for 10–23 word lines in the bench).
- M6.2 first-chunk streaming against raw Kokoro generate is **false**; implement
  sentence chunking in `tts_server` or accept full-buffer TTFC.
- Do not start TTS.3 client tiering until TTS.0.3 / 0.4 close and ADR is Accepted.

## References

- `docs/TTS_HANDOFF.md`
- `spike/kokoro_bench.py`, `scripts/verify_tts.sh`
- `docs/adr/0003-speech-on-ada.md` (speech placement)
- Existing Ada Kokoro sidecar sketch: `~/bin/tts_server_kokoro.py` on `:8092`
