# ADR 0006 — House presence via Home Assistant person entities

**Status:** Accepted  
**Date:** 2026-08-05  
**Milestone:** Phase 2 (P2.1)

## Context

ADR 0005 deferred HA presence mapping. The household already tracks people as
Assist-exposed `person.*` entities (see `ha_presence_voice` skill). COMSTAR
needs an authoritative “who’s home” snapshot for voice and future planners
without driving the hallway attention FSM from house cameras.

## Decision

1. **Source of truth for house presence is Home Assistant** `person.*` (and
   optionally `zone.home`), polled over the existing HA token used by
   `HaAgentClient` — not MQTT/Frigate in P2.1.
2. **COMSTAR uid → HA entity** is configured in yaml:

   ```yaml
   presence:
     ha_person_by_uid:
       zlatko: person.zlatko_lakisic
   ```

   Later (P2.3): derive from FreeIPA attrs/groups; yaml remains an override.
3. **API:** bridge serves `GET /v1/presence/home` →
   `{ts, people:[{uid, displayName, ha_entity, state}]}`.
4. **Non-goal (P2.1):** house presence does **not** open AO sessions, change
   attention state, or replace local Pi camera identity. Local vision remains
   the identity terminator at the terminal.
5. **Voice:** optional bridge-local `HomeDataIntent` summary so “who’s home”
   does not require an AO tool loop.
6. **MQTT / Frigate event ingest** is deferred to P2.1b if poll latency is
   insufficient.

## Consequences

- Requires Assist-exposed `person.*` entities (same constraint as HA MCP skills).
- Snapshot can be stale by one poll interval; acceptable for spoken summary.
- Attention multi-user (P2.2) stays independent of this ADR.
