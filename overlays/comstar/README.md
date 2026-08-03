# COMSTAR session overlay (AO layout)

Mirrors Agentic Orchestration catalog folders under `agentic-orchestration-tool/config/`,
but is loaded as an **ephemeral session overlay** via AO Reach — not merged into the
AO disk catalogs on Ada.

```
overlays/comstar/
├── agent_providers/     # client.* agents (Reach OverlayPacker)
├── agent_skills/        # AO skill YAML (+ optional instructions.md)
├── agent_harnesses/     # Platform-style smoke profiles (harness_profile:)
├── harnesses/           # User harness packs (scenarios for live inject / eval)
└── mcp_providers/       # Bridge tunnel bootstrap (stdio_tunnel) — not AO stdio
```

## Load paths

| Folder | Who reads it |
|--------|----------------|
| `agent_providers/` | Reach `OverlayPacker` → `session_overlay_register` |
| `agent_skills/` | Reach `OverlayPacker` (ids → `client.*`; inject into agent `backstory` when listed) |
| `mcp_providers/` | COMSTAR bridge `loadOverlayMcpProviders` + `LocalMcpHost` (tunnel) |
| `agent_harnesses/` | Documentation / future smoke runner (`harness_profile` on agents) |
| `harnesses/` | Live E2E / eval packs (e.g. `scripts/google_voice_data_e2e.sh`) |

## MCP note

`mcp_providers/*.yaml` keep AO-style metadata (`description`, `planner_hint`, …) plus
COMSTAR fields (`transport: stdio_tunnel`, `npx_package`, `env_from`). They are **not**
AO `stdio` / `streamable_http` disk catalog entries.

## Skills note

AO `direct_agent` currently passes `skills: []`. COMSTAR therefore **injects** listed
skill bodies into the agent `backstory` at pack time so voice turns still receive them.
Skills are also registered on the session overlay for future workflow attachment.
