# HANDOFF — TTS engine: Qwen3-TTS on Ada, Piper on the Pi as fallback

**Audience:** Cursor / Claude Code, plus one human operator.  
**Companions:** `docs/CONTRACTS.md` §2, §6, §7 · `docs/IMPLEMENTATION_PLAN.md` M6 · `docs/adr/0008-tts-engine.md` · `docs/adr/0003-speech-on-ada.md`  
**Status:** proposal (retargeted 2026-09-23). Nothing product-cut until room listen + Ada bench gates pass.  
**ADR:** `docs/adr/0008-tts-engine.md`

---

## Why (and why not Kokoro)

Piper is small/fast and flat across a hallway — expected for Tier 2 resilience.  
Kokoro-82M was chosen as a drop-in sherpa model (Apache-2.0, tiny VRAM). Listening
and Arena (~Elo 1056 vs ~1128 top open weight) show the flatness is **the model**.
We also already proved Kokoro gives **no early first audio** (TTFC ≈ full synth) and
Ada `venv-tts` **cannot** get a working CUDA EP — so GPU quality/latency for Kokoro
is blocked on ORT/sherpa, not config.

**Pick: Qwen3-TTS 1.7B on Ada** (Apache 2.0, PyTorch/transformers → Ada CUDA works
without fixing ORT; native streaming; voice design; fits 16 GB with CPAI).  
**Fallback try if room fails:** Chatterbox (MIT).  
**Keep:** Piper on Pi as Tier 2 unchanged.

---

## Target architecture

```
  Raspberry Pi                              AI server (RTX 4000 Ada)

  comstar-bridge                            comstar-tts (Reach hello.speech)
   └ PreferReachTts                          └ Qwen3-TTS 1.7B  (Tier 1)
      ├ primary  ──── HTTP /v1/audio/speech ──►   PyTorch + CUDA
      │                  → wav (stream later)
      └ fallback ──► comstar-tts :8091
                      └ sherpa-onnx + Piper     (Tier 2)
                         en_US-ryan-high

  assets/speech/*.wav + phrase banks
   └ bake with the same frozen Qwen3 voice (Tier 0)
```

| Tier | Engine | Where | Used for |
|---|---|---|---|
| 0 | Qwen3, baked | Pi assets / phrase banks | Greetings, narration lines, sorry/offline |
| 1 | Qwen3-TTS 1.7B, live | Ada | Every real answer |
| 2 | Piper, live | Pi CPU | Ada down / speechClient null / text not in Tier 0 |

**Bridge stays dumb:** same `POST /v1/audio/speech` shape. Add
`scripts/tts_server_qwen.py` next to `tts_server_kokoro.py`. Do **not** change
`PreferReachTts`, `HttpTts`, audio server, or kiosk for the engine swap.

**Do not** build request-level race, mid-stream splice across engines, or
voice-matching. Turn-boundary failover only. Tier 0 is resilience.

---

## Gates (before Accept / cutover)

1. **Room listen @ ~3 m** on Pi speakers — pick voice via Qwen3 **voice design**, freeze it.  
2. **Bench on Ada** — TTFC, RTF, VRAM idle vs CPAI contended → `docs/BASELINES.md`  
   (do not trust ~97 ms marketing numbers on A4000).  
3. **Canonical sample rate** → CONTRACTS §2.  
4. Bake Tier 0 + narration banks with the frozen voice so fixed lines match live.

Kokoro BASELINES §12 stays as historical evidence (CPU, no early chunk, no CUDA EP).

---

## Implementation sketch (after gates)

1. Ada venv: PyTorch + Qwen3-TTS weights; `tts_server_qwen.py` OpenAI-compatible.  
2. Point Reach `hello.speech` TTS URL (or `COMSTAR_TTS_URL` / override) at it.  
3. Optional: stream first audio into bridge later — **not** required for first cut if
   full WAV still beats Kokoro TTFC; prefer native stream when wiring is cheap.  
4. Leave `comstar-tts` Piper unit on Pi.  
5. Retire Kokoro as product Tier 1 in runbooks; keep script for archaeology.

Community crib: [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS),
[OpenAI FastAPI wrapper](https://github.com/groxaxo/Qwen3-TTS-Openai-Fastapi),
[streaming engine](https://github.com/X-Square-Robot/Qwen3TTS-Streaming).

---

## As-built reminder (unchanged by this retarget)

- Prefer Reach `speechClient.synthesize`; else `COMSTAR_TTS_URL` / Piper (`speech_routing.dart`, ADR 0003).  
- `formatForSpeech` before synth (`speak_format.dart`).  
- Kiosk plays loopback `audioUrl`; follow-up on `speak.ended` (ADR 0001).
