# ADR 0005 — FreeIPA directory identity binding

**Status:** Accepted  
**Date:** 2026-08-03  
**Milestone:** Phase 2 (directory); does not block M0–M9 exit

## Context

COMSTAR auto-login today is face recognition only: CodeProject.AI returns a
free-form `userid` string, the vote resolver locks it, and that string becomes
AO session headers (`x-agentic-user-name` / `comstar-<userid>`). There is no
directory, no display-name source, and no binding between biometric store IDs and
a household identity. Voice does not identify who spoke.

FreeIPA is already the LAN identity store. We need a binding so visual (and later
voice) matches resolve to the same FreeIPA person without turning COMSTAR into a
Kerberos IdP or storing biometrics in LDAP.

## Decision

1. **Login target is AO/COMSTAR session only** — face/voice resolve opens or
   switches the Reach session. No Kerberos ticket minting, no desktop SSO, no HA
   presence mapping in this ADR (group names may be reserved for later ACL).
2. **FreeIPA `uid` is the canonical COMSTAR/AO identity** used in session headers
   and Google token paths.
3. **Modality map via custom attrs** on an auxiliary `comstarPerson` objectClass:
   - `comstarFaceId` — CPAI enroll/recognize string (default equals `uid`)
   - `comstarVoiceId` — reserved for future speaker enrollment
   Lookup always searches the modality attr, never assumes CPAI string == `uid`.
4. **Biometrics stay out of LDAP** — face images/embeddings remain in CodeProject.AI;
   future voiceprints stay in a speaker service. LDAP holds directory + bindings +
   groups only.
5. **COMSTAR remains the identity terminator** — the Pi bridge resolves
   `faceId → PersonProfile` before `SessionBridge.start`. AO continues to trust
   forwarded headers; it does not bind to FreeIPA.
6. **Fail closed when directory is required** — LDAP miss or hard error with
   `directory.require: true` → treat as unknown / guest. Fail-open
   (`require: false`) is for `comstar.dev.yaml` bring-up only.
7. **Directory sidecar** — read-only Python helper (`ldap3`) exposes HTTP resolve
   to the bridge. Bind as a FreeIPA service account with search-only rights on
   `cn=users,cn=accounts,$BASEDN`. Optional planner LDAP MCP is deferred until
   the session path is solid (`guest_allowed: false` when added).

## Consequences

- Enrollment must verify the IPA user exists and set `comstarFaceId` before CPAI
  `face/register` (see `scripts/enroll_face.sh` and `docs/ldap/`).
- Greeter and kiosk `displayName` come from LDAP `displayName`/`cn`, falling back
  to `uid`.
- IdentityResolver continues to vote on the **biometric faceId**; directory
  resolve runs once after votes, before `OpenSession`.
- House-wide HA presence and Kerberos SSO remain explicit non-goals until a
  follow-up ADR.

## Schema

See [`docs/ldap/comstar.schema`](../ldap/comstar.schema) and
[`docs/ldap/README.md`](../ldap/README.md).
