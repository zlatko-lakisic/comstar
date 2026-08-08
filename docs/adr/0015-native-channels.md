# ADR 0015 — Native multi-channel messaging (no OpenClaw)

**Status:** Accepted  
**Date:** 2026-08-07  
**Milestone:** M11 (extends ADR 0010)  
**Companions:** ADR 0010, `docs/PHASE2_PLAN_PROACTIVITY_AND_CHANNEL.md`, Google
`pairing.qr` UX (`terminal/bridge/lib/google/`)

## Context

Household messaging away from the hallway needs the same surfaces people already
use (Telegram, WhatsApp, Signal). Product direction: **COMSTAR owns the channels**
in the Ada `channel/` package, using the same kiosk QR pairing interaction
already proven for Google Workspace — not OpenClaw.

Constraints that still hold from ADR 0010:

- Distinct AO session ids (`comstar-<uid>-channel` vs terminal).
- Allowlist / silence for unknown senders.
- Dual-surface announce (M11.6) via Ada HTTP.

## Decision

1. **No OpenClaw messaging plane.**
2. **Providers live in `ChannelMux`** with these backends only:

   | Provider | Backend | Notes |
   |---|---|---|
   | Telegram | Bot API long-poll | Shipping default |
   | WhatsApp | **Meta Cloud API** | Official only; **no** Baileys/whatsmeow |
   | Signal | **`signal-cli` HTTP JSON-RPC** | Operator links device once; COMSTAR uses daemon |

3. **Identity = QR pairing + bindings store.** Voice (“link Telegram / WhatsApp /
   Signal”) → `pairing.qr` → Ada `$COMSTAR_DATA_DIR/channel/bindings.json`.
   Guests cannot pair.
4. **Pairing URLs**
   - Telegram: `https://t.me/<bot>?start=pair_<token>`
   - WhatsApp: `https://wa.me/<digits>?text=pair_<token>`
   - Signal: `https://signal.me/#p/<E164>` (user types `pair_<token>`; no prefill)
5. **WhatsApp inbound** via Meta webhook on Ada
   `POST/GET /v1/whatsapp/webhook` (same port as announce HTTP; must be
   reachable from Meta or via a tunnel).
6. **Signal inbound** via signal-cli SSE `/api/v1/events`; outbound via
   `/api/v1/rpc` `send`.

## Consequences

- CONTRACTS §11 / RUNBOOK §9c document env vars per provider.
- Unofficial WhatsApp clients are explicitly out of scope (ban risk).
- Cloud API is a Business number (not personal WhatsApp Web session).
- signal-cli must be linked and running before “link Signal” works for users.

## References

- Package: `channel/` (`whatsapp.dart`, `signal.dart`, `telegram.dart`)
- Pairing UX: `pairing.qr`, `qrSvg()`
- ADR 0010 (session isolation, silence model)
