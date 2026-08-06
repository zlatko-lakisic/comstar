# COMSTAR — Phase 2 Presence Plan

**Status:** active  
**Companion:** `docs/IMPLEMENTATION_TRACKER.md` (Phase 2 section), `docs/BACKLOG.md`, `docs/CONTRACTS.md`  
**Does not block on:** Phase 1 deferred wake ONNX, human STT labels, soak wall-clock.

## Milestone map

| # | Name | Effort | Ships |
|---|---|---|---|
| P2.0 | Scaffold | 4h | Docs, CONTRACTS stubs, ADRs |
| P2.1 | House-wide presence (HA) | 12h | Snapshot API + voice summary |
| P2.2 | Multi-user terminal | 20h | PresenceSet, session switch, re-greet |
| P2.3 | Directory extras | 10h | LDAP MCP, voice_id resolve, IPA→HA map |
| P2.4 | Avatar + sentiment | 16h | SVG mood from replies |
| P2.5 | Full-duplex + AEC | 24h+ | Barge-in with reference-channel AEC |

```
P2.0 → P2.1 ─┐
     └→ P2.2 ─┴→ P2.3
          └→ P2.4 → P2.5
```

## Exit criteria (Phase 2 done)

- [x] `GET /v1/presence/home` matches HA for mapped uids; voice summary works
- [x] Two enrolled faces → presence set; primary switch greets + remaps memory
- [x] LDAP planner MCP smoke on Ada; voice_id resolve path tested
- [x] Spoken replies change SVG emblem mood
- [x] Full duplex shipped **or** explicitly deferred in BACKLOG + ADR
  (barge-in + AEC module shipped; `half` remains default until soak)

## Phase 1 leftovers (parallel)

Wake ONNX+ROC · human STT labels · soak `summary.json` — see tracker Phase 1 deferred.

## Phase 3+ (out of scope)

Additional terminals · session handoff · shared KB distribution.
