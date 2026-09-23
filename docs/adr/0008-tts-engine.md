# ADR 0008 — TTS engine: Qwen3-TTS on Ada, Piper fallback on Pi

**Status:** Proposed (retargeted 2026-09-23; Kokoro path retired as Tier 1)  
**Date:** 2026-08-07 (original); **Revised:** 2026-09-23  
**Milestone:** M6 / TTS.0–TTS.8  
**Supersedes (partially):** latency assumption in ADR 0003 that local Piper is
the quality/latency default for spoken answers.  
**Supersedes (Tier 1 target):** prior draft that named Kokoro-82M as primary live TTS.

## Context

Hallway listening makes Piper (`en_US-ryan-high`) feel synthetic. Kokoro-82M was
the interim Tier-1 candidate (sherpa-onnx, Apache-2.0, tiny VRAM), but product
listening and Arena numbers show the flatness is **the model**, not the COMSTAR
pipeline: TTS Arena Elo ~1056 (~32nd) vs top open-weight ~1128. Piper sits below
that again.

Kokoro also fails two COMSTAR-specific constraints we already measured:

1. **No true early first audio** — sherpa callback is buffer-complete; TTFC ≈ full
   synth (BASELINES §12). ADR previously worked around this with sentence chunking.
2. **CUDA EP blocked** on Ada `venv-tts` ORT — CPU-only Kokoro; GPU path is an
   ORT/sherpa build problem, not a one-line config.

Field check for a **locally hosted, permissively licensed** engine on a **~16 GB**
card (RTX 4000 Ada class):

| Model | License | VRAM | Streaming first audio | Notes |
|---|---|---|---|---|
| **Qwen3-TTS 1.7B** (also 0.6B) | Apache 2.0 | fits | yes (claimed ~97 ms; re-bench on Ada) | 10 languages, voice design, ~3 s clone, native streaming |
| CosyVoice 3.0 | Apache 2.0 | ~4 GB | yes (~150 ms) | solid; slightly less expressive than Qwen3 |
| Chatterbox / Turbo | MIT | ~6 GB | yes (~470 ms) | emotion control; slower TTFC; **fallback if Qwen3 fails room test** |
| Orpheus 3B | Apache 2.0 | 8–12 GB | yes | expressive; heaviest |
| Fish Audio S2 Pro | research | 12–24 GB | yes | Elo ~1128 but license + VRAM rule it out |
| Kokoro 82M (retired Tier 1) | Apache 2.0 | 2–3 GB | no early first audio | fast/tiny; flat prosody |

Full handoff: `docs/TTS_HANDOFF.md`.

## Decision (in progress)

1. **Primary live TTS (Tier 1):** **Qwen3-TTS 1.7B** on the AI server (PyTorch /
   transformers — uses Ada CUDA without fixing ORT). Keep the existing
   OpenAI-compatible `POST /v1/audio/speech` → `audio/wav` (or streamed audio)
   contract so `PreferReachTts` / `HttpTts` / kiosk stay unchanged. New sidecar:
   `scripts/tts_server_qwen.py` (crib FastAPI wrappers / streaming engines; do not
   invent a new bridge API).
2. **Fallback (Tier 2):** Pi Piper (`comstar-tts`) with **turn-boundary** failover
   only (no mid-utterance engine splice). Piper is resilience, not quality.
3. **Greetings / fixed lines / narration banks (Tier 0):** bake with the **same**
   Qwen3 voice chosen in the room (voice design once, freeze).
4. **Streaming:** prefer **native** first-audio from Qwen3; do not depend on
   Kokoro-style sentence chunking workarounds for product TTFC.
5. **If Qwen3 fails hallway listen:** try **Chatterbox** next (MIT, expressive;
   ~470 ms TTFC still beats full-utterance Kokoro).

## Gates before Accept (do these before product cutover)

| Gate | Why |
|---|---|
| **Room listen @ ~3 m** on Pi HDMI speakers | Hallway intelligibility ≠ headphone naturalness; decides the voice |
| **Bench on Ada A4000** | Claimed 97 ms TTFC will not hold; record TTFC / RTF / VRAM idle vs CPAI contended → BASELINES |
| **Canonical sample rate** | Lock in CONTRACTS §2 after measuring Qwen3 (+ Piper 22050) |
| **Voice freeze** | One voice-design pick; bake Tier 0 + phrase banks to match live |

Do **not** start TTS.3 client tiering or remove Piper until those gates close and
this ADR is Accepted.

## Prior Kokoro evidence (historical)

Kept so we do not re-litigate ORT/CUDA or “maybe chunking fixes flatness.”

| Item | Result |
|---|---|
| TTS.0.1 RTF idle + CPAI contended | Done on **CPU**; CUDA EP unavailable |
| TTS.0.2 streaming | API callback exists; Kokoro fires **once** with full buffer |
| Measured TTFC p50 (CPU, sid 0) | ~1.3–1.5 s ≈ full synth |

## Consequences

- Bridge/client path (ADR 0003 Reach prefer + `COMSTAR_TTS_URL` fallback, ADR 0001
  kiosk sink, `formatForSpeech`) **unchanged** above the sidecar.
- New Ada dependency: PyTorch + Qwen3-TTS weights in a dedicated venv (not
  sherpa `venv-tts`).
- Kokoro sidecar (`tts_server_kokoro.py`) remains reference / optional; not the
  product Tier 1 target.
- Latency budget “first chunk ~150 ms” becomes a **real** target only after Ada
  bench — not marketing numbers from other GPUs.

## References

- `docs/TTS_HANDOFF.md`
- `docs/adr/0003-speech-on-ada.md` (speech placement)
- `scripts/tts_server.py` (Pi Piper), `scripts/tts_server_kokoro.py` (retired Tier 1 sketch)
- Upstream: [QwenLM/Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS),
  [OpenAI-compatible FastAPI wrapper](https://github.com/groxaxo/Qwen3-TTS-Openai-Fastapi),
  [Qwen3TTS-Streaming](https://github.com/X-Square-Robot/Qwen3TTS-Streaming)
- Field notes: TTS Arena / local TTS comparisons (2026) — Elo ~1056 Kokoro vs ~1128 top open weight
