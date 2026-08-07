# ADR 0012 — Admin host network (Wi‑Fi + IPv4)

**Status:** Accepted  
**Date:** 2026-08-07  
**Companions:** `docs/CONTRACTS.md` (`/admin/api/network`), ADR 0011 (nmcli sudoers)

## Context

Road bring-up and hallway ops need to join travel Wi‑Fi and set ethernet/wlan
IPv4 (DHCP vs static) without SSH. NetworkManager is already the control plane
for Road VPN.

## Decision

1. **API:** `GET/POST /admin/api/network` (token-gated when LAN-bound).
2. **Backend:** whitelisted `nmcli` actions only (radio, scan, wifi connect /
   disconnect / forget, ipv4 auto|manual). No raw shell.
3. **Reuse** Road VPN sudoers (`NOPASSWD: /usr/bin/nmcli`).
4. **Scope:** physical `ethernet` + `wifi` devices. Ignore VPN/tun/bridge.
5. **Secrets:** Wi‑Fi PSK accepted in POST; never written to structured logs.
6. **UI:** Ops tab **Network** (beside Road VPN / Logs).

## Consequences

- Mis-set static IP can drop admin reachability until console/SSH recovery.
- Captive portals remain out of scope (same as ADR 0011).
- Changing Wi‑Fi while using Wi‑Fi for the admin session may interrupt the UI.
