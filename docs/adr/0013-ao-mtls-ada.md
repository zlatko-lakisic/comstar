# ADR 0013 — AO Reach mTLS to Ada

**Status:** Accepted  
**Date:** 2026-08-07  
**Companions:** `docs/CONTRACTS.md` §4 + `/admin/api/ao_mtls`, Reach `v0.4.1`, AO ≥ 1.29

## Context

Ada AO engine now serves **HTTPS with required client certificates** on
`:8765` (direct, not via Warpgate). Cleartext HTTP is disabled. COMSTAR must
enroll once, persist PEMs, and open `wss` with that material.

## Decision

1. **Engine URL** is `orchestration.base_url` and must be `https://…` when
   `orchestration.mtls.enabled` is true (Ada: `https://10.0.10.16:8765`).
2. **Material** lives under `~/.local/share/comstar/ao-mtls/` (or
   `orchestration.mtls.material_dir`): `cert.pem`, `key.pem`, `ca.pem`, plus a
   small `meta.json` (client name, enrolled_at). Never commit PEMs.
3. **Enroll once** with Ada-minted one-time token via Reach `ReachMtlsEnroller`
   (`trustEnrollmentCa: true` on first pair). Client cert ~365d; no daily
   re-auth. Re-pair from Admin when needed.
4. **Session open** passes `ReachMtlsConfig(materialDir: …)`. Fail closed if
   mTLS enabled but material missing.
5. **Admin Ops tab “AO pairing”** is the primary operator UX; `make ao-mtls-enroll`
   is for headless SSH.
6. **Speech sidecars** remain cleartext HTTP (out of scope).

## Consequences

- Warpgate `orchestration.token` is optional / transitional for non-mTLS hosts.
- Operators need `openssl` on the Pi for CSR generation.
- Cert expiry requires manual re-pair until auto-renew exists.
