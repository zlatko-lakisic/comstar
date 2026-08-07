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
| Active milestone | **M10+M11 landed 2026-08-07** — ADR 0015 QR pairing; deploy/UAT + soak remain |
| Overall Phase 1 | ~85% (M9 soak wall-clock open) |
| Overall Phase 2 | Presence + **proactivity M10** + **channel M11** (UAT open) |
| Last updated | 2026-08-07 |
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
- 24 h soak (M9.4) — running `20260807-141443` (started after hardening deploy); prior partial `20260805-025615` (~21.6h)
- Wake retune (M9.5) — blocked on ONNX (force-wake documented in RUNBOOK §4 / TESTING §T5b)

### Open blockers / gaps

| ID | Item | Blocks | Owner note |
|---|---|---|---|
| B8 | Wake ONNX not trained | M4 ROC | Needs room recordings + openWakeWord AutoTrainer env |
| B9 | TalkingHead GLB not wired | M7 lip-sync | Intentional SVG shipping; `assets/comstar.glb` present (gitignored) |
| B11 | STT fixtures need human labels | M6 accuracy gate | Auto-bench PASS 12/12 vs Pi whisper; not human GT |
| B12 | Terminal MCP hangs AO tools | M5 tunnel | Keep `COMSTAR_TERMINAL_MCP` off; in-bridge sleep/volume |
| B13 | Vision MCP not registered on AO | M5 who_is_present | Code + AO-shaped YAML ready; needs Ada SSH, frame feed, catalog install — `docs/handoffs/ada-mcp-register.md` |
| B14 | LDAP MCP not registered on AO | P2.3 smoke | Code + AO-shaped YAML ready; needs Ada SSH, FreeIPA bind, catalog install — same handoff |
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
| M9 | Hardening & soak | 16h | `in_progress` | ~80% | M9.1–M9.3/M9.6–M9.7 done 2026-08-07; M9.4 soak wall-clock; M9.5 blocked (wake ONNX) |

---

## Next concrete actions (human / hardware)

1. **Deploy** Pi bridge (announce + `announce.channel_url`) + Ada `comstar-channel` (`TELEGRAM_BOT_TOKEN` + allowlist + `COMSTAR_CHANNEL_TOKEN` / bind)
2. **UAT-10 / UAT-11** — hallway announce + Telegram continuity / unknown silence / urgent→Telegram when away
3. Let **24h soak** finish (`20260807-141443`); read `summary.json` vs §T5
4. Human-label STT fixtures; wake ONNX when recordings exist
5. Register `ldap_mcp` + `vision_mcp` on Ada

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
- [x] M10.0 proactivity ground truth (ADR 0009, CONTRACTS §4, BASELINES §13) — 2026-08-07
- [x] M10.1–M10.6 announcement product path (queue/sources/gate/machine/greeter/admin) — 2026-08-07
- [x] M11.0 text-channel ground truth (ADR 0010, CONTRACTS §4/§11, probe fixture) — 2026-08-07
- [x] M11.1–M11.5 + M11.7–M11.8 scaffold (`channel/`, text_responder, privacy docs) — 2026-08-07
- [x] M11.6 dual-surface announce live wiring (bridge CAS + channel `/v1/announce`) — 2026-08-07
- [x] ADR 0015 native multi-channel + QR pairing (no OpenClaw) — 2026-08-07
- [ ] UAT-10/11 operator sign-off

Living plan: `docs/PHASE2_PLAN_PROACTIVITY_AND_CHANNEL.md`.

### M11 progress detail

| Slice | Status | Notes |
|---|---|---|
| M11.0 session probe + ADR 0010 | `done` | Same session id unsafe → `comstar-<uid>-channel` |
| M11.1 Ada placement + systemd | `done` | `deploy/systemd/comstar-channel.service` example |
| M11.2 Channel abstraction | `done` | `Channel` + `ChannelMux` + Telegram long-poll |
| M11.3 Allowlist silence | `done` | tests: unknown = zero outbound; multi-sender fan-out |
| M11.4 text_responder overlay | `done` | + `text_output` skill (markdown OK); overlay constraint tests |
| M11.5 Session wiring | `done` | `ChannelSessionManager`, idle reap, SIGTERM stop, **AO mTLS** |
| M11.6 Announce → channel gate | `done` | bridge `evaluateChannelSurface` + Ada `/v1/announce`; CAS delivered-once |
| M11.7 Rate limit | `done` | per-sender + daily cap tests |
| M11.8 Docs / privacy | `done` | README + CONTRACTS §11 + RUNBOOK §9c + admin Channel health |
| ADR 0015 QR pairing | `done` | Voice → `pairing.qr` → Telegram deep link; bindings store; WA/Signal stubs |