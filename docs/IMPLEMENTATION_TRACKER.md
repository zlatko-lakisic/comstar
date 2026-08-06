# COMSTAR — Implementation Tracker

**Purpose:** track Phase 1 leftovers and Phase 2 Presence.  
**Sources of truth:** `docs/IMPLEMENTATION_PLAN.md`, `docs/PHASE2_PLAN.md`,
`docs/CONTRACTS.md`, `docs/DEV_LOOP.md`.  
**Environment facts:** `docs/BASELINES.md`. Overflow: `docs/BACKLOG.md`.

**Rules**
- Phase 1: do not start M(n+1) until every M(n) exit criterion is checked.
- Phase 2: follow `docs/PHASE2_PLAN.md` order (P2.0 → … → P2.5). Phase 1 deferred
  items do **not** block P2.0–P2.1.
- When an exit criterion is met, check it here **and** note the date.
- If CONTRACTS change, update CONTRACTS first, then code, then this tracker.

**Status legend:** `not_started` · `in_progress` · `blocked` · `done` · `deferred`

---

## Current position

| Field | Value |
|---|---|
| Active milestone | **Phase 2 Presence** — P2.0–P2.5 implemented 2026-08-05 |
| Overall Phase 1 | ~80% (walk-up UAT done; wake/STT-labels/soak deferred) |
| Overall Phase 2 | software path complete; hallway UAT / Ada MCP register open |
| Last updated | 2026-08-05 |
| Board | `comstar-ai` Pi 4B 4GB @ `192.168.89.34` — SSH Host `comstar` |
| Vision backend | CodeProject.AI `10.0.10.16:32168` — face `zlatko` enrolled |
| AO Reach | `10.0.10.16:8765` — greeter + voice live; **Ada speech sidecars** in use |
| Speech | Prefer Reach `SpeechClient` → Ada `:8093`/`:8092`; Pi STT/TTS fallback units still active |
| Memory | Phase 1 rolling + Phase 2 durable FTS on `comstar-memory` `:8792` |
| Product code | bridge + audio + kiosk + memory under `/opt/comstar/src` systemd user units |

### Phase 1 deferred (do not block Phase 2)

- Wake-word ONNX train + ROC (M4) — force-wake documented; no training data yet
- Live STT **human** labels (M6) — 12 live fixtures pass circular auto-bench; GT review open
- ~~Walk-up greet-by-name UAT (M8)~~ — **passed 2026-08-05** (operator sign-off)
- 24 h soak (M9) — running `~/.local/share/comstar/soak/20260805-025615/` (started ~02:56)

### Open blockers / gaps

| ID | Item | Blocks | Owner note |
|---|---|---|---|
| B8 | Wake ONNX not trained | M4 ROC | Needs room recordings + openWakeWord AutoTrainer env |
| B9 | TalkingHead GLB not wired | M7 lip-sync | Intentional SVG shipping; `assets/comstar.glb` present (gitignored) |
| B11 | STT fixtures need human labels | M6 accuracy gate | Auto-bench PASS 12/12 vs Pi whisper; not human GT |
| B12 | Terminal MCP hangs AO tools | M5 tunnel | Keep `COMSTAR_TERMINAL_MCP` off; in-bridge sleep/volume |
| B13 | Vision MCP not registered on AO | M5 who_is_present | Code in `mcp/vision_mcp/`; needs Ada catalog + frame source |
| B14 | LDAP MCP not registered on AO | P2.3 smoke | Code in `mcp/ldap_mcp/`; catalog YAML ready |
---

## Milestone rollup (Phase 1)

| # | Name | Effort | Status | Progress | Gate |
|---|---|---|---|---|---|
| M0 | Ground truth | 6h | `done` | 100% | CPAI+AO+baselines+ADR |
| M1 | Skeleton & config | 8h | `done` | 100% | three processes + deploy |
| M2 | Vision client | 10h | `done` | 100% | offline tests + live CPAI |
| M3 | Attention state machine | 12h | `done` | 100% | property + branch tests |
| M4 | Audio pipeline | 14h | `in_progress` | ~75% | wake ROC + hardware UAT |
| M5 | AO Reach session | 12h | `in_progress` | ~85% | greeter/voice/Google live; MCP tunnel partial |
| M6 | Voice round trip | 10h | `in_progress` | ~90% | Ada speech live; fixture accuracy UAT open |
| M7 | Avatar & kiosk | 14h | `in_progress` | ~75% | SVG emblem + mood; GLB optional |
| M8 | First contact | 10h | `in_progress` | ~80% | walk-up greet UAT passed 2026-08-05 |
| M9 | Hardening & soak | 16h | `in_progress` | ~25% | soak started 2026-08-05; failure matrix scaffolded |

---

## Next concrete actions (human / hardware)

1. Human-label `testdata/stt/live-bridge-*.json` transcripts; re-run `bench_stt --require-live 10`
2. Record “hey comstar” + negatives → train `models/hey_comstar.onnx` + ROC
3. Let soak finish 24h → read `~/.local/share/comstar/soak/*/summary.json`
4. Deploy Phase 2 bridge/kiosk/audio; curl `GET /v1/presence/home`; UAT two-face primary switch
5. Register `ldap_mcp` + `vision_mcp` on Ada AO catalog
6. Optional: enable `COMSTAR_AEC=1` + monitor source for full duplex soak

---

## Phase 2 — Presence

Living plan: `docs/PHASE2_PLAN.md`. ADRs: `0006-house-presence-ha`, `0007-full-duplex-aec`.

| # | Name | Effort | Status | Gate |
|---|---|---|---|---|
| P2.0 | Scaffold | 4h | `done` | PHASE2_PLAN + CONTRACTS stubs + ADRs |
| P2.1 | House-wide presence (HA) | 12h | `done` | `/v1/presence/home` + HomeDataIntent |
| P2.2 | Multi-user terminal | 20h | `done` | PresenceSet + keep recognizing + primary switch |
| P2.3 | Directory extras | 10h | `done` | LDAP MCP + voice_id + haPerson attr |
| P2.4 | Avatar + sentiment | 16h | `done` | speak.mood → SVG emblem moods |
| P2.5 | Full-duplex + AEC | 24h+ | `done` | barge-in path + AEC module + RUNBOOK (half default) |

### Phase 2 exit checklist

- [x] `GET /v1/presence/home` + voice summary path (needs live HA for curl UAT)
- [x] Multi-user presence set + primary switch + greeter debounce + memory key via session
- [x] LDAP planner MCP + voice_id resolve + inject stub; IPA `comstarHaPerson` attr
- [x] Spoken replies set `speak.mood` → SVG emblem mood params
- [x] Full duplex barge-in in machine when `duplex: full`; AEC helper + RUNBOOK; half remains default
