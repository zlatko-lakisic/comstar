# Phase 2 / deferred backlog

Items intentionally **not** in M0–M9. See `docs/IMPLEMENTATION_PLAN.md`
“Deferred to Phase 2”.

## Directory / identity

- [x] ADR 0005 + FreeIPA `comstarPerson` schema + enroll convention
- [x] Directory sidecar + bridge resolve (faceId → uid) with cache
- [ ] **LDAP MCP for planner** — `lookup_user` / `list_comstar_users` wrapping the
  directory sidecar; overlay YAML with `guest_allowed: false`. Session open must
  not depend on this MCP (CONTRACTS §3b / ADR 0005).
- [ ] Voice speaker-ID → `comstarVoiceId` → same directory resolve
- [ ] HA presence / user mapping from IPA groups (1B)
- [ ] Kerberos / FreeIPA desktop SSO from biometrics (explicit non-goal unless new ADR)

## Other Phase 2 (from implementation plan)

Custom rigged COMSTAR avatar · full-duplex barge-in with AEC · sentiment→gesture
mapping · multi-user simultaneous presence · house-wide presence via existing
camera events · session handoff between terminals · morning briefing batch flow ·
email and Slack triage.
