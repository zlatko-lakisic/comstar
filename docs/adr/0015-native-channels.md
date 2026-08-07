# ADR 0015 — Native multi-channel messaging (no OpenClaw)

**Status:** Accepted  
**Date:** 2026-08-07  
**Milestone:** M11 (extends ADR 0010)  
**Companions:** ADR 0010, `docs/PHASE2_PLAN_PROACTIVITY_AND_CHANNEL.md`, Google
`pairing.qr` UX (`terminal/bridge/lib/google/`)

## Context

Household messaging away from the hallway needs the same surfaces people already
use (Telegram, WhatsApp, Signal, …). An earlier draft routed that plane through
OpenClaw. Product direction is the opposite: **COMSTAR owns the channels** in
the Ada `channel/` package, using the same kiosk QR pairing interaction already
proven for Google Workspace.

Constraints that still hold from ADR 0010:

- Distinct AO session ids (`comstar-<uid>-channel` vs terminal).
- Allowlist / silence for unknown senders.
- Dual-surface announce (M11.6) via Ada HTTP, not a third-party gateway.

## Decision

1. **No OpenClaw messaging plane.** Do not call `openclaw message send`, do not
   treat OpenClaw plugins as the product channel stack, and do not document
   OpenClaw as required for WhatsApp/Signal/Telegram.
2. **Providers live in `ChannelMux`.** Telegram Bot API remains the first
   shipping provider. WhatsApp and Signal join as additional `Channel`
   implementations (official APIs and/or dedicated local sidecars — documented
   per provider; ban-risk unofficial clients require an explicit operator opt-in).
3. **Identity = QR pairing + bindings store.** Voice at the terminal
   (“link Telegram / WhatsApp / Signal”) starts a short-lived pairing attempt.
   The bridge shows the existing `pairing.qr` kiosk overlay (same contract as
   Google device-code). On success Ada persists
   `(provider, sender_id) → userid` under
   `$COMSTAR_DATA_DIR/channel/bindings.json` (merged with static
   `COMSTAR_CHANNEL_ALLOWLIST`). Guests cannot pair.
4. **Telegram deep link first.** Pairing URL is
   `https://t.me/<bot>?start=pair_<token>`; the channel daemon completes the
   binding when that `/start` arrives. Spoken user code mirrors Google.
5. **WhatsApp / Signal.** Operator must enable a provider backend (env + ADR
   notes). User-facing pairing still uses `pairing.qr` once the backend can
   emit a scan URL or session QR. Until configured, voice reports “not set up”.

## Consequences

- CONTRACTS §11 describes native mux + pairing HTTP (`/v1/pairing/*`).
- Bridge uses `announce.channel_url` only (no `openclaw_*` config).
- README privacy: enabling any provider sends chat off-LAN via that network.
- OpenClaw may still exist on the operator’s Mac for unrelated experiments; it
  is not part of COMSTAR’s messaging architecture.

## References

- Package: `channel/`
- Pairing UX reuse: `pairing.qr`, `qrSvg()`, Google coordinator lifecycle
- ADR 0010 (session isolation, silence model)
