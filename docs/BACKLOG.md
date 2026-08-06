# Phase 2 / deferred backlog

Items intentionally **not** in M0–M9. Active Phase 2 work lives in
`docs/PHASE2_PLAN.md` and `docs/IMPLEMENTATION_TRACKER.md`.

## Directory / identity

- [x] ADR 0005 + FreeIPA `comstarPerson` schema + enroll convention
- [x] Directory sidecar + bridge resolve (faceId → uid) with cache
- [x] **LDAP MCP for planner** — P2.3 (`lookup_user` / `list_comstar_users`)
- [x] Voice speaker-ID → `comstarVoiceId` → same directory resolve — P2.3 (inject stub)
- [x] HA presence map via yaml + optional LDAP `comstarHaPerson` — P2.1/P2.3
- [ ] Kerberos / FreeIPA desktop SSO from biometrics (explicit non-goal unless new ADR)

## Presence / attention / avatar / audio (Phase 2 tracks)

- [x] House-wide presence via HA poll — P2.1 (MQTT/Frigate = P2.1b still open)
- [x] Multi-user simultaneous presence at one terminal — P2.2
- [x] Sentiment → SVG gesture mapping — P2.4
- [x] Full-duplex barge-in with AEC scaffolding — P2.5 (ADR 0007); **keep `half` default** until soak
- [ ] Custom rigged COMSTAR avatar / TalkingHead GLB — optional, not Phase 2 gate
- [ ] P2.1b MQTT/Frigate house presence events (if poll latency insufficient)
- [ ] Dual-stream reference capture wired end-to-end on Pi (Speex live soak)

## Later (Phase 3+)

Session handoff between terminals · shared KB distribution · morning briefing
batch flow · email and Slack triage · additional hallway terminals.
