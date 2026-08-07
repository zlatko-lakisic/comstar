# ADR 0011 — Road VPN phone-home (OpenVPN + L2TP)

**Status:** Accepted  
**Date:** 2026-08-07  
**Companions:** `docs/CONTRACTS.md` (admin `/admin/api/road`), `docs/RUNBOOK.md` §Road VPN

## Context

COMSTAR terminals live on trusted home LAN subnets and talk to Ada over
plain HTTP. On the road the Pi will not have those subnets; it must reach Ada
(and HA) through a VPN “phone home” path without ferrying secrets in git.

Operators want **both** OpenVPN and L2TP/IPsec, selectable from the admin
console, with automatic bring-up when off-home.

## Decision

1. **Home = any local IPv4 in configured CIDRs** (default
   `192.168.89.0/24`, `192.168.90.0/24`, `172.16.90.0/24`). No SSID matching;
   no gateway ping required for the at-home decision.
2. **Control plane = NetworkManager connection names.** Bridge ups/downs
   named connections via `nmcli` (optional `sudo -n`). Profiles and secrets
   live in NM / local state under `~/.local/share/comstar/road/`, never in
   committed yaml.
3. **Protocols:** `openvpn` | `l2tp` | `auto` (prefer OpenVPN connection if
   present, else L2TP). Admin can force connect/disconnect and edit runtime
   knobs without rewriting `comstar.yaml`.
4. **When off-home and `road.enabled`:** monitor the tunnel; probe `health_url`
   (default Ada AO `/health`); heal (reconnect / bounce) on drop or probe
   failure with exponential backoff. **When at home:** bring COMSTAR VPN
   connections down (leave other VPNs alone).
5. **Admin:** setup UI → prerequisites → credentials → **Initialize** (enable +
   connect). Ongoing control via `GET/POST /admin/api/road`. Secrets never
   echoed on GET.
6. **Host packages:** `scripts/install-road-vpn.sh` / `make road-vpn`.

## Consequences

- Pi needs NM OpenVPN and/or L2TP plugins + sudoers for non-interactive `nmcli`.
- Ada / home gateway must expose the chosen VPN endpoint **and** an HTTP health
  target reachable over the tunnel.
- Travel Wi‑Fi captive portals are out of scope; operator must get internet
  before phone-home can succeed.
