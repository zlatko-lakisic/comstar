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

AO `direct_agent` (v1.28.1+) attaches agent-entry `skills` from the session
overlay catalog and **strips** Reach-baked `## …` backstory skill text before
re-injecting via the catalog path. Reach still packs `skills:` on the agent and
registers skill bodies in `session_overlay_register`; the backstory bake remains
as a compatibility path for older AO builds.

### Google Workspace voice skills (`mcp-server-google-workspace@0.2.6`)

| Skill | Tools covered |
|-------|----------------|
| `google_workspace_voice` | Auth / pairing / routing |
| `calendar_voice` | `calendar_list_*`, `calendar_create_event` |
| `gmail_voice` | `gmail_list/search/read/send_email` |
| `drive_voice` | `drive_*` list/search/read/write/share/delete/doc |

Wire all four on `client.voice_responder` (plus HA / spoken_output). Desktop OAuth is
required for Gmail and full Drive; TV device-code is Calendar (+ limited Drive).

Live eval pack: `harnesses/voice_google/` (reads, clarification probes, optional
disposable writes named **COMSTAR harness probe** — see that pack’s README).
