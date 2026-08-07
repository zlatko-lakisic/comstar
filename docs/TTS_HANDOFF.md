# HANDOFF — TTS engine: Kokoro on the AI server, Piper on the Pi as fallback

**Audience:** Cursor / Claude Code, plus one human operator.
**Companions:** `docs/CONTRACTS.md` §2, §6, §7 · `docs/IMPLEMENTATION_PLAN.md` M6 · `README.md` §Latency budget
**Status of this document:** proposal. Nothing here is VERIFIED until TTS.0 exit criteria are met.
**ADR target:** `docs/adr/0008-tts-engine.md` (0003 is already `speech-on-ada`).

---

## Why we are changing this

Piper is the fastest and smallest local engine and also the flattest. `en_US-ryan-high` is a good Piper voice and it still reads as synthetic across a room, which is exactly the setting COMSTAR lives in. Kokoro-82M is a StyleTTS2-derived 82M-parameter model, Apache-2.0 with open weights, 24 kHz output, and sherpa-onnx supports it via `OfflineTtsKokoroModelConfig`, so this is a model swap inside the runtime we already ship, not a new service stack.

The cost is that Kokoro does not fit the Pi. On the RTX 4000 Ada it should be fine — **if** the sherpa-onnx build includes the CUDA EP. TTS.0.1 must measure that; the Ada `venv-tts` package may be CPU-only today.

So the engine moves to the server. That reverses the earlier "STT/TTS on the Pi for latency" decision when the choice was Piper-local versus Piper-remote. Kokoro on the Ada plus a LAN hop should beat Piper on the Pi for any utterance longer than a sentence — confirm in TTS.0.1.

---

## Target architecture

```
  Raspberry Pi 4                              AI server (RTX 4000 Ada)

  comstar-bridge                              comstar-tts        :8091
   └ lib/tts.dart                              └ sherpa-onnx + Kokoro
      ├ primary  ──── HTTP ──────────────────────►  (GPU if EP available)
      │
      └ fallback ──► comstar-tts-local :8091
                      └ sherpa-onnx + Piper
                         en_US-ryan-high
                         (CPU, already deployed)

  assets/speech/*.wav
   └ pre-baked with Kokoro at build time
```

| Tier | Engine | Where | Used for |
|---|---|---|---|
| 0 | Kokoro, baked at build time | `assets/speech/` on the Pi | Greetings, fallback lines, tones |
| 1 | Kokoro, live | AI server | Every real answer |
| 2 | Piper, live | Pi, CPU | Tier 1 unavailable and text not in Tier 0 |

**Do not** build request-level race, mid-stream splice, or voice-matching. Health check, circuit breaker, turn-boundary failover only. Tier 0 is the resilience story.

---

## TTS.0 — Ground truth (verification only; no product client code)

### TTS.0.1 — Kokoro on the Ada, measured
`spike/kokoro_bench.py` + `scripts/verify_tts.sh`. Record RTF, time-to-first-chunk, VRAM, idle vs CodeProject.AI contended → `docs/BASELINES.md`.

### TTS.0.2 — Confirm streaming
Read sherpa-onnx Python API **source/docs on the installed package**. Do not guess from Piper alone. Write finding into CONTRACTS §6.

### TTS.0.3 — Voice selection
Listen on the real Pi speakers. Record pick in ADR 0008.

### TTS.0.4 — Sample rate
Kokoro 24 kHz vs Piper 22.05 kHz. Recommendation: 24 kHz canonical. CONTRACTS §2.

### Exit criteria
- [x] Contended and uncontended RTF in BASELINES.md (CPU; CUDA EP unavailable)
- [x] Streaming answered in CONTRACTS §6 (API yes; Kokoro buffer-complete empirically)
- [ ] Voice chosen via real speakers (TTS.0.3)
- [ ] Canonical sample rate in CONTRACTS §2 (TTS.0.4)
- [x] `docs/adr/0008-tts-engine.md` drafted (Proposed; 0.3/0.4 open)

---

## Implementation (TTS.1–TTS.8)

Deferred until TTS.0 exit criteria are met. See original handoff body for task breakdown, config keys, latency table, tests, and risks.
