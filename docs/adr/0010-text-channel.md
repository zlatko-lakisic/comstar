# ADR 0010 — Text channel (Telegram + session isolation)

**Status:** Accepted (M11.0 ground truth)  
**Date:** 2026-08-07  
**Milestone:** M11  
**Companions:** `docs/PHASE2_PLAN_PROACTIVITY_AND_CHANNEL.md`,
`docs/fixtures/channel_session_probe_20260807T1830Z.log`, ADR 0009

## Context

M11 adds one messaging surface so a conversation started at the hallway terminal
can continue away from home. The channel is internet-facing ingress into a system
that can drive Home Assistant — allowlist silence is the security model.

Two questions:

1. **Which channel?** Telegram vs WhatsApp vs Signal.
2. **Session semantics:** can terminal + channel share
   `x-agentic-session-id: comstar-<uid>`, or must they use distinct ids?

## Decision

1. **Channel = Telegram** (Bot API long-poll). Straightforward, no phone-number
   pairing, no unofficial API ban risk. Abstraction (`Channel`) keeps a second
   surface cheap later; do not build one now.
2. **Distinct session ids.** Same userid; **never** share the terminal session id.
   - Terminal: `comstar-<uid>`
   - Channel: `comstar-<uid>-channel`
   - Announcer (M10): `comstar-<uid>-announce-<id>`
3. **Continuity is userid / KB scoped**, not a shared session overlay. Cross-surface
   memory merge is a knowledge/memory property, not AO session-id sharing.
4. **Runs on Ada** (`comstar-channel` systemd unit), co-located with AO — not on
   the Pi — so the channel works when the room is empty.
5. **Allowlist or silence.** Unknown Telegram sender ids get **zero** outbound
   (no error, no greeting). Rate limit per sender + daily orchestration cap.

## Evidence (M11.0.1)

Live probe `spike/channel_session_probe.dart` against AO @ `10.0.10.16:8765`
(2026-08-07), consistent with M10.0 announce findings:

| Case | Result |
|---|---|
| Same session id, terminal first → channel `stop(clearRemote)` | **Unsafe** — terminal `directAgent` fails (`unknown agent_provider_id 'client.greeter'`) |
| Same session id, channel first | Turns may succeed, still **forbidden** (shared clearRemote hazard) |
| Diff session ids (`…-channel`), both orderings | **Safe** — terminal healthy during/after channel stop |
| 3× channel stop cycles with distinct ids | No growth of terminal `registeredAgentIds` |

Fixture: `docs/fixtures/channel_session_probe_20260807T1830Z.log`.

## Consequences

- `channel/lib/session.dart` opens `SessionBridge` with
  `x-agentic-session-id: comstar-<uid>-channel`.
- Text uses `client.text_responder` + `text_output` skill (markdown OK) — **not**
  `voice_responder` / `spoken_output`.
- README privacy model must state that enabling M11 means message text leaves the
  LAN via Telegram.
- M11.6 announce dual-surface gate: terminal presence wins; urgent+absent →
  channel; delivered-once globally (`shouldDeliverToChannel`).

## References

- Probe: `spike/channel_session_probe.dart`
- Package: `channel/`
- CONTRACTS §4 (session lifecycle) · §11 (channel protocol stub)
- ADR 0009 (same-session-id hazard for announcer)
