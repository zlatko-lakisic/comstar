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
2. **COMSTAR uid → HA entity** may be configured in yaml (aliases / overrides):

   ```yaml
   presence:
     ha_person_by_uid:
       zlatko: person.zlatko_lakisic
   ```

   The bridge also **auto-discovers** Assist-exposed `person.*` via the HA
   agent list API and matches spoken names to `friendly_name`. Yaml wins on
   entity_id conflict. Skip non-people (`google_home`, service accounts).
   Directory `comstarHaPerson` (P2.3) remains an overlay; yaml still wins.
3. **API:** bridge serves `GET /v1/presence/home` →
   `{ts, people:[{uid, displayName, ha_entity, state}]}`.
4. **Non-goal (P2.1):** house presence does **not** open AO sessions, change
   attention state, or replace local Pi camera identity. Local vision remains
   the identity terminator at the terminal.
5. **Voice:** bridge-local `HomeDataIntent` for “who’s home”, “where is
   \<name\>”, and “when did \<name\> leave” so presence does not require an AO
   tool loop. Named lookups use yaml aliases plus discovered people. Away
   answers reverse-geocode person GPS against `zone.home` and speak by proximity
   tier (local place → city → city/state → city/country). Leave-time uses HA
   history for the last `home`→away transition. When HA state is `unknown`, the
   bridge may append Frigate `person_last_seen` as a camera-history fallback.
6. **MQTT / Frigate event ingest** is deferred to P2.1b if poll latency is
   insufficient.

## Consequences

- Requires Assist-exposed `person.*` entities (same constraint as HA MCP skills).
- Snapshot can be stale by one poll interval; acceptable for spoken summary.
- Attention multi-user (P2.2) stays independent of this ADR.
