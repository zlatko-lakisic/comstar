# ADR 0009 — Proactive announcements (session ownership + delivery)

**Status:** Accepted (M10.0 ground truth)  
**Date:** 2026-08-07  
**Milestone:** M10  
**Companions:** `docs/PHASE2_PLAN_PROACTIVITY_AND_CHANNEL.md`,
`docs/fixtures/announce_session_probe_20260807T1820Z.log`, `docs/BASELINES.md` §13

## Context

COMSTAR today only speaks when a person or sensor drives the attention machine.
M10 adds **proactive announcements** — external events that become spoken lines
delivered to a specific person at a chosen moment. Generating announcement text
needs an AO turn, which may run while a terminal `SessionBridge` for that
identity is already open.

Two designs were on the table:

1. **Short-lived announcer bridge** — open a second `SessionBridge`,
   `directAgent`, `stop()`.
2. **Intent-only queue** — never open a second bridge; terminal generates text
   at delivery time.

## Decision

1. **Use distinct session ids for the announcer.** Same userid is fine;
   **same `x-agentic-session-id` is not.** Naming:
   - Terminal (product): `comstar-<uid>`
   - Announcer (ephemeral): `comstar-<uid>-announce-<ulid-or-ts>`
2. **Short-lived announcer `SessionBridge` is allowed** for text generation when
   using the announce session-id pattern. Empirically verified 2026-08-07.
3. **Never share the terminal session id.** Probe showed: when two bridges share
   one session id and the announcer `stop(clearRemote: true)`, the terminal’s
   subsequent `directAgent` fails (`unknown agent_provider_id 'client.greeter'`
   — overlay cleared under the shared session).
4. **Delivery policy sketch (M10.3):**
   | Condition | Action |
   |---|---|
   | Recipient present at terminal + idle | Speak (subject to quiet hours) |
   | Recipient present + mid-turn | Defer until turn ends (do not barge) |
   | Attention `Sleeping` | Speak is still audible today (sink not muted by sleep); prefer ExitSleep / phase wake for UX before urgent speak |
   | Sink muted / no sink | Defer or route to channel (M11); never silent-drop urgent without log |
   | Expired (`expiresAt`) | Drop silently; log `announce_expired` |
5. **Non-goals here:** M11 text channel, device-initiated mid-turn barge-in,
   source→Speak bypass of the gate, product `lib/announce/*` (starts M10.1).

## Evidence (M10.0.1)

| Case | Result |
|---|---|
| Announcer alone | OK; agents cleared after stop |
| Same session id, terminal first → ann stop | **Unsafe** — terminal turn broken after ann stop |
| Same session id, ann first | Turns succeeded in probe, but still **forbidden** (shared clearRemote hazard) |
| Diff session ids, both orderings | **Safe** — terminal healthy during/after ann stop |
| 3× announce leak cycles | No growth of terminal `registeredAgentIds`; ann clears |

Fixture: `docs/fixtures/announce_session_probe_20260807T1820Z.log`.

## Consequences

- M10.2 sources may generate text via an ephemeral announce session **or** enqueue
  intent for terminal-time generation; prefer ephemeral when no terminal session
  is open, and either when one is open (diff session id).
- M10.3 gate must treat attention sleep ≠ audio mute (see BASELINES §13).
- Do not start M10.1 queue code until this ADR is the written rule (now).

## References

- Probe: `spike/announce_session_probe.dart`
- CONTRACTS §4 session lifecycle (updated M10.0)
- Handoff plan: `docs/PHASE2_PLAN_PROACTIVITY_AND_CHANNEL.md`
