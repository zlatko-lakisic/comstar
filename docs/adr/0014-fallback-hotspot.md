# ADR 0014 — Offline fallback Wi‑Fi hotspot

**Status:** Accepted  
**Date:** 2026-08-07  
**Companions:** `docs/CONTRACTS.md` (`admin.qr`, network), ADR 0012 (nmcli)

## Context

When the hallway Pi has **no ethernet and no client Wi‑Fi**, operators cannot
reach Admin on `:8781`. The debug admin QR also has no LAN IP to encode.

## Decision

1. **Detect uplink loss** periodically (ethernet connected with IPv4, or Wi‑Fi
   client — not our AP profile). When neither is up, bring up a local SoftAP.
2. **NetworkManager** shared Wi‑Fi AP via existing `NOPASSWD: nmcli` sudoers:
   connection id `comstar-hotspot`, `ipv4.method=shared`, address
   **`10.87.65.1/24`** (DHCP via NM’s dnsmasq). Unique vs home `192.168.89/90`
   and `172.16.90`.
3. **SSID** `COMSTAR-<hostname>` (≤32 chars), open auth for setup simplicity.
4. **Admin QR** uses hotspot IP when that is the only address; envelope includes
   `hotspot: true` and `ssid`. Kiosk shows SSID under the QR. When eth/wlan
   client returns, tear down AP, clear `ssid`, regenerate QR for the uplink IP.
5. **Show QR while hotspot is active** even if kiosk `debugUi` is false — recovery
   path. Still requires admin token; never log the token.
6. Disable with `COMSTAR_HOTSPOT=0`.

## Consequences

- SoftAP occupies `wlan0`; client Wi‑Fi is disconnected until uplink returns.
- Open AP is only up while offline — still a local attack surface; token still
  gates Admin.
- Phones must join the SSID before scanning the QR (same L2 as `10.87.65.1`).
