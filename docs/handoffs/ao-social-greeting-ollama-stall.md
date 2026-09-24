# Handoff: Social greeting → 190 s AO (Ollama GPU/CPU + MCP re-attach)

**Status:** Open (diagnosis refined 2026-09-23; COMSTAR timeline verified)  
**Date:** 2026-09-23  
**For:** AO / agentic-orchestration Cursor on Ada **and** COMSTAR (Pi routing + TTS)  
**Related turn:** `followup-1790205287129` · AO run `48e4d5c8085e42a19ee4605647524acb`  
**Wall clock:** 19:14:54–19:18:04 EDT · `turn_total` **189.5 s**

---

## Ask

Two stacked problems turned a hallway greeting into a ~3 minute wait. Fix in
priority order below. Do **not** treat “8k prompt” as the sole root cause.

1. **P0 (Ada):** Explain why `qwen2.5:14b-instruct` took **161.6 s** for
   8,194 prompt + 26 completion tokens on an RTX 4000 Ada (should be ~5–10 s
   at Q4 if fully on GPU).
2. **P0 (Ada):** Enforce a hard **tool-free social step** after every MCP/skill
   augment — no CrewAI/ReAct, small model, short system prompt.
3. **P1 (COMSTAR + AO):** One shared social-phrase contract so Pi closed-form and
   AO social short-circuit cannot drift; keep greetings off AO when routing allows.
4. **P1 (COMSTAR + Ada TTS):** Pre-render heartbeat WAVs; benchmark/fix Qwen3-TTS
   RTF (~3.7× slower than real time on the final clip).

**Targets:** greeting **&lt; 3 s** end-to-end; normal AO request **&lt; 10 s**.

---

## Verdict (corrected)

| Claim | Status |
|---|---|
| Timeline adds up (STT ~0.4 s + route ~1 s + Ollama ~162 s + final TTS ~23 s ≈ 190 s) | **Confirmed** |
| Ollama call is where the wall time went | **Confirmed** |
| Prompt size alone explains 161 s | **Incomplete** — prompt is a multiplier on a slow backend |
| Likely CPU offload / cold load / GPU contention with Qwen3-TTS | **Primary hypothesis — unconfirmed** |
| Social plan said “no tools” but HA + Google MCP were still on the crew step | **Confirmed** |
| Pi social matcher “missed” the phrase | **Wrong for this turn** — see §Pi routing |

---

## Evidence (this turn)

### Pi bridge

| Wall (EDT) | Event | Span |
|---|---|---|
| 19:14:54 | STT: `How are you doing today?` | `stt` 375 ms |
| 19:14:55 | `dynamic_chat` / `utterance_route` · `utterance_routing=ao` · `lane=ao` | — |
| 19:14:59 … 19:17:26 | Five AO heartbeat lines via Qwen3-TTS `:8091` | TTS 7.1 / 8.5 / 13.1 / 16.3 / 11.7 s |
| 19:17:41 | `direct_agent_ok` · “I'm doing well…” | AO wait ≈ 165 s |
| 19:18:04 | Final speak · TTS 22.8 s for 6.1 s audio | `turn_total` 189464 ms |

### Ada run trace (`48e4d5c8…jsonl`)

| Kind | Detail |
|---|---|
| `planner_short_circuit` | `reason=social` → `client.text_responder` (~0.4 s, no planner LLM) |
| `plan` / `decision` | Message: “briefly **without tools**” · top-level `mcps: []` |
| `crewSteps` / `step_start` | Still lists `mcps: ["home_assistant", "client.google_workspace"]` |
| `model_call` | `qwen2.5:14b-instruct` · **prompt_tokens=8194** · **completion_tokens=26** · **latency_ms=161603.2** |
| `run_end` | `I'm doing well, thank you for asking! How about you?` |

Prompt preview on the model call already shows HA tool names
(`assist_satellite_hass_broadcast`, `homeassistant_get_live_context`, …) —
CrewAI tool-calling / ReAct shape, not a tiny chat prompt.

---

## Problem A — Why was Ollama ~162 s? (P0)

**Math check:** 8.2k prefill + 26 decode on a 14B Q4 on RTX 4000 Ada should be
on the order of **5–10 s** if the model is fully resident on GPU. **161.6 s**
implies ~50 tok/s prompt eval — **CPU-class**, not GPU-class.

**Likely causes (most likely first):**

1. **Partial CPU offload.** After Qwen3-TTS, both STT sidecars, CodeProject.AI,
   and ffmpeg, free VRAM was tight (~12 GB free quoted). `qwen2.5:14b` needs
   ~9 GB weights + ~1.6 GB KV for an 8k prompt + buffers → near the edge.
   Ollama may have moved layers to CPU.
2. **Cold load.** Ollama may have been unloaded earlier to free VRAM for TTS;
   this call’s 161 s may include model load.
3. **GPU contention.** Five live Qwen3-TTS heartbeats ran on the same GPU while
   the LLM was prefilling.

**8194 is also a red flag.** It sits just over a common `num_ctx` of **8192**,
suggesting the prompt may have been **truncated**. If so, the true prompt was
larger and Ollama silently dropped the tail — still not a full explanation for
161 s, but it means tool bloat is worse than the logged count.

### Confirm before changing product code

While a turn is in flight on Ada:

```bash
ollama ps
# PROCESSOR column: look for CPU/GPU split (e.g. 30%/70% CPU/GPU)
```

For the model call, capture (add to AO `usage.jsonl` if missing):

- `load_duration`
- `prompt_eval_duration`
- `eval_duration`

If `prompt_eval_duration` alone is ~160 s → confirm CPU/prefill story.  
If `load_duration` is large → cold load.  
If PROCESSOR shows CPU% → offload; every AO turn is slow, not just greetings.

---

## Problem B — Why did a “no tools” social step still get MCPs? (P0)

Social short-circuit selected `client.text_responder` and advertised no tools,
then **something after plan selection re-attached** HA + Google. With tools
attached, CrewAI switches to a **tool-calling (ReAct) prompt** and embeds every
tool schema. Home Assistant alone is huge; that is most of the ~8k tokens.
COMSTAR memory / `{topic}` wrappers add more.

**Suspects (AO):**

- `_maybe_augment_mcp_*` / `_maybe_augment_skills_*` after planning
- Session / client overlay tool list from COMSTAR register
- MCP/skills baked into the responder’s catalog entry / backstory

### Hard rule (checked after every augment)

A **social** step must have:

- **no MCPs**
- **no skills**
- **no RAG**
- **no conversation history dump**

And it should **skip CrewAI entirely**: one direct chat completion with a short
system prompt. It does not need 14B — a **3B** (or smaller) model answers
“I'm doing well” in well under a second when GPU-resident.

---

## Problem C — Pi should not have sent this to AO (P1)

### What actually happened on this turn

COMSTAR already matches this utterance locally:

```text
# terminal/bridge/lib/social_intent.dart
how are you | how you doing | hows it going | …
```

`How are you doing today?` **would** parse as `SocialIntentKind.howAreYou`.

The miss was **not** the phrase list — it was **`utterance_routing=ao`**, which
**skips content closed-form** (including social) and forwards to AO
(`docs/VOICE_CLOSED_FORM.md`, `docs/CONTRACTS.md`). Live log:

```text
utterance_routing=ao  lane=ao  evt=dynamic_chat
```

So: with routing=`ao`, every greeting burns an AO run. Prefer **`split`** for
hallway product so social stays on the Pi (&lt; 2 s with phrase bank + TTS).

### Still do: shared social contract (P1)

AO’s social short-circuit and the Pi matcher must not drift. Maintain **one**
authoritative list:

- checked into a contract file both sides consume, **or**
- served by AO and cached on the Pi

Use it for: Pi closed-form (when `split`), AO social short-circuit, and tests
(`terminal/bridge/test/fixtures/closed_form_utterances.yaml` + AO detector tests).

---

## Problem D — Qwen3-TTS is a real second issue (P1)

Final answer: **22.8 s** to synthesize **6.1 s** of audio → RTF ≈ **3.7**.
That call ran **after** Ollama finished, so GPU contention with the LLM does
**not** explain it. A 0.6B CustomVoice model on this GPU should be faster than
real time.

**Check:**

- fp32 vs bf16 / fp16
- flash attention present or missing
- full-clip generate vs streaming first audio

**Heartbeats:** do **not** synthesize live. They are fixed phrases — pre-render
WAV once (or on phrase-bank refresh) and `paplay`/kiosk-play the files. That
also stops heartbeat TTS from loading the GPU during Ollama prefill (Problem A.3).

---

## Work order

| Pri | Owner | Action | Done when |
|---|---|---|---|
| **P0** | Ada | Capture `ollama ps` + `load_duration` / `prompt_eval_duration` / `eval_duration` on a live slow turn | Know CPU vs cold vs contended |
| **P0** | Ada | If CPU offload: fix VRAM budget (unload TTS during LLM, quant, or keep 14B pinned) | Prefill back to GPU rates |
| **P0** | Ada | Hard assert: social step `mcps=[]`, `skills=[]`, no CrewAI — direct small-model chat | Greeting AO path &lt; ~1 s model time |
| **P1** | COMSTAR | Default hallway to `utterance_routing=split` (or exempt social even under `ao`) | Greeting never hits AO in product |
| **P1** | Both | Shared social phrase contract + tests | Pi and AO detectors cannot diverge |
| **P1** | COMSTAR | Pre-render / cache heartbeat WAVs | No live TTS during AO wait |
| **P1** | Ada | Solo Qwen3-TTS bench + fix RTF | Final speak ≪ audio duration |

---

## Out of scope / do not confuse

- This is **not** primarily a COMSTAR bridge bug in STT or routing math — the
  timeline is correct.
- Do **not** “fix” by only trimming the social system prompt while MCP augment
  still re-attaches HA.
- Do **not** treat Kokoro rollback as the greeting fix; social must leave AO
  (or become a tiny direct chat) regardless of TTS engine.

---

## Pointers

- Canvas (COMSTAR timeline): workspace
  `canvases/how-are-you-turn-breakdown.canvas.tsx` (update root-cause callout if
  reopened — half-right narrative superseded by this handoff)
- Ada traces: `/var/projects/agentic-orchestration/agentic-orchestration-tool/__orchestrator_run_traces__/48e4d5c8085e42a19ee4605647524acb.jsonl`
- COMSTAR social matcher: `terminal/bridge/lib/social_intent.dart`
- Routing: `docs/VOICE_CLOSED_FORM.md`, `orchestration.utterance_routing`
- Prior AO handoffs: `docs/handoffs/ao-direct-agent-empty-irrigation.md`,
  `docs/handoffs/ao-ha-tool-stall-prose.md`
