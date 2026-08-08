# ADR 0016 — Nextcloud personal productivity (complement Google)

**Status:** Accepted (spike)  
**Date:** 2026-08-07  
**Companions:** `docs/CONTRACTS.md` (tunnel MCP), ADR 0005 (FreeIPA uid)

## Context

Household Nextcloud holds files, notes, calendar, tasks, contacts, and mail for
accounts that are **not** the Google Workspace identities already linked via
`client.google_workspace`. COMSTAR should answer hallway questions against that
data without inventing a custom Nextcloud API client.

## Decision

1. **Off-the-shelf MCP** — Pin
   [`nextcloud-mcp-server`](https://pypi.org/project/nextcloud-mcp-server/)
   (cbcoutinho), started via `LocalMcpHost.startStdioCommand` (`uvx` preferred)
   and tunnelled as `client.nextcloud`. No in-repo Nextcloud protocol code beyond
   Login Flow v2 pairing and credential storage.
2. **Complement Google** — Separate MCP, skills, and credentials. Explicit
   “Nextcloud / my cloud / NAS” utterances attach `client.nextcloud` alone;
   Google-named or legacy calendar/mail phrases keep `client.google_workspace`.
   Ambiguous “my calendar” without a cloud hint stays Google (existing habit).
3. **Identity** — Per FreeIPA uid (faceId aliases like Google). Guests never get
   the MCP. Missing credentials soft-skip registration; voice still works.
4. **Auth** — Store app password under
   `~/.local/share/comstar/nextcloud/<userid>.json` (`0600`). Pair via Nextcloud
   **Login Flow v2** (voice + QR) or Admin `POST /admin/api/nextcloud`. Shared
   instance URL from `NEXTCLOUD_HOST` (env) with optional per-user host override.
5. **Surfaces (v1)** — Files/WebDAV, Notes, Calendar, Tasks, Contacts, Mail via
   voice skills. No announce source, Talk, Photos, or Deck in this spike.

## Consequences

- Bridge hosts need Python ≥3.11 and `uv`/`uvx` (or a PATH
  `nextcloud-mcp-server` entrypoint).
- Tool surface is large (100+ tools); skills must steer tool choice for voice.
- AGPL MCP dependency runs as a local subprocess — acceptable for LAN terminal;
  do not relicense COMSTAR.
