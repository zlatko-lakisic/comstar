# COMSTAR — Implementation Tracker

**Purpose:** single place to track Phase 1 progress.  
**Sources of truth for *what* to build:** `docs/IMPLEMENTATION_PLAN.md`, `docs/CONTRACTS.md`, `docs/DEV_LOOP.md`.  
**Environment facts:** `docs/BASELINES.md`.

**Rules**
- Do not start M(n+1) until every M(n) exit criterion below is checked.
- When an exit criterion is met, check it here **and** note the date.
- If CONTRACTS change, update CONTRACTS first, then code, then this tracker.
- Effort numbers are ideal hours from the plan (~112 h total Phase 1).

**Status legend:** `not_started` · `in_progress` · `blocked` · `done`

---

## Current position

| Field | Value |
|---|---|
| Active milestone | **M4 / M6–M9 hardware & UAT gates** (software path live) |
| Overall Phase 1 | ~80% |
| Last updated | 2026-08-05 |
| Board | `comstar-ai` Pi 4B 4GB @ `192.168.89.34` — SSH Host `comstar` |
| Vision backend | CodeProject.AI `10.0.10.16:32168` — face `zlatko` enrolled |
| AO Reach | `10.0.10.16:8765` — greeter + voice live; **Ada speech sidecars** in use |
| Speech | Prefer Reach `SpeechClient` → Ada `:8093`/`:8092`; Pi STT/TTS fallback units still active |
| Memory | Phase 1 rolling + Phase 2 durable FTS on `comstar-memory` `:8792` |
| Product code | bridge + audio + kiosk + memory under `/opt/comstar/src` systemd user units |

### Remaining before Phase 1 exit (needs you / wall-clock)

- Wake-word ONNX train + ROC (M4) — force-wake documented; no training data yet
- Live STT **human** labels (M6) — 12 live fixtures pass circular auto-bench; GT review open
- Walk-up greet-by-name UAT (M8) — face `zlatko` enrolled; stand in frame
- 24 h soak (M9) — **started** `~/.local/share/comstar/soak/20260805-025615/` (AO probe fixed)

### Open blockers / gaps

| ID | Item | Blocks | Owner note |
|---|---|---|---|
| B8 | Wake ONNX not trained | M4 ROC | Needs room recordings + openWakeWord AutoTrainer env |
| B9 | TalkingHead GLB not wired | M7 lip-sync | Intentional SVG shipping; `assets/comstar.glb` present (gitignored) |
| B11 | STT fixtures need human labels | M6 accuracy gate | Auto-bench PASS 12/12 vs Pi whisper; not human GT |
| B12 | Terminal MCP hangs AO tools | M5 tunnel | Keep `COMSTAR_TERMINAL_MCP` off; in-bridge sleep/volume |
| B13 | Vision MCP not registered on AO | M5 who_is_present | Code in `mcp/vision_mcp/`; needs Ada catalog + frame source |
---

## Milestone rollup

| # | Name | Effort | Status | Progress | Gate |
|---|---|---|---|---|---|
| M0 | Ground truth | 6h | `done` | 100% | CPAI+AO+baselines+ADR |
| M1 | Skeleton & config | 8h | `done` | 100% | three processes + deploy |
| M2 | Vision client | 10h | `done` | 100% | offline tests + live CPAI |
| M3 | Attention state machine | 12h | `done` | 100% | property + branch tests |
| M4 | Audio pipeline | 14h | `in_progress` | ~75% | wake ROC + hardware UAT |
| M5 | AO Reach session | 12h | `in_progress` | ~85% | greeter/voice/Google live; MCP tunnel partial |
| M6 | Voice round trip | 10h | `in_progress` | ~90% | Ada speech live; fixture accuracy UAT open |
| M7 | Avatar & kiosk | 14h | `in_progress` | ~70% | SVG emblem shipping; GLB optional |
| M8 | First contact | 10h | `in_progress` | ~55% | face enrolled; walk-up UAT open |
| M9 | Hardening & soak | 16h | `in_progress` | ~25% | soak started 2026-08-05; failure matrix scaffolded |

---

## Next concrete actions (human / hardware)

1. Record “hey comstar” + negatives → train `models/hey_comstar.onnx` + ROC
2. Human-label `testdata/stt/live-bridge-*.json` transcripts; re-run `bench_stt --require-live 10`
3. Stand in frame → walk-up greet-by-name UAT-8
4. Let soak finish 24h → read `~/.local/share/comstar/soak/*/summary.json`
5. Decide: keep SVG emblem (current) vs wire TalkingHead + branded GLB
