# Handoff: AO `direct_agent` empty reply (COMSTAR irrigation / HA tools)

**Status:** Resolved on AO side by **v1.28.1** (2026-08-04). Empty silent-success →
`DirectAgentEmptyAnswerError` / `ok: false`. Skills + MCP defaults attach on
`direct_agent`; Reach-baked backstory skill text is stripped before catalog
re-inject. Remaining: model may still skip HA tools or pass bad args
(`area=garden`); COMSTAR `home_assistant_voice` skill steers to irrigation
sensors — reconnect COMSTAR after Ada deploy (done 2026-08-04 ~12:30 EDT).

**For:** AO / agentic-orchestration Cursor on Ada  

---

## Ask (original)

Investigate why `direct_agent` with `client.voice_responder` + `mcpProviderIds: ["home_assistant"]` returns **HTTP/WS success with empty answer text** for irrigation questions, and why tool turns take long enough that COMSTAR used to cut them off at 15s.

COMSTAR must **not** answer these locally — Pi is I/O only; AO is the brain.

---

## Repro (live, 2026-08-04 ~11:30 EDT)

On hallway terminal after face engage + session overlay:

| Time (EDT) | Event |
|---|---|
| 11:29:52 | `direct_agent` “What are you up to today?” + `home_assistant` → **OK ~7s**, 170 chars |
| 11:30:33 | STT: `How much water did our garden get yesterday?` |
| 11:30:33 | `direct_agent` same agent + `mcp: ["home_assistant"]` |
| 11:30:52 | COMSTAR `direct_agent_empty` — AO returned **empty string** (~**19.5s** elapsed) |
| — | User heard **silence** (COMSTAR bug: 15s Responding timeout left state before empty fallback could speak — fixed on COMSTAR; root cause still AO empty) |

Pi log evidence:

```text
evt=direct_agent text="How much water did our garden get yesterday?" mcp=["home_assistant"]
evt=direct_agent_empty turn_id=followup-1785857425698   # ~19.5s later
```

Contrast: non-tool-ish chat with HA MCP attached still answered. Calendar that turn was answered by a **local** Google shortcut (not AO) — ignore for this bug.

---

## COMSTAR call shape (Reach WebSocket)

Session headers:

- `x-agentic-user-name: zlatko`
- `x-agentic-session-id: comstar-zlatko`

Overlay register (session agents): `client.greeter`, `client.voice_responder` (+ skills injected into backstory).  
Stock MCP used on voice turns: **`home_assistant` only** (tunnel `client.google_workspace` deliberately omitted on default voice — AO 1.28 OpenAI tool-name / `127.0.0.1` issue).

```json
{
  "type": "direct_agent",
  "agentProviderId": "client.voice_responder",
  "text": "How much water did our garden get yesterday?",
  "mcpProviderIds": ["home_assistant"],
  "questionId": "comstar-…"
}
```

COMSTAR client timeout for HA-only turns: **60s** (`session.dart`).  
Attention-machine Responding floor (after fix): **90s**.  
Configured `orchestration.timeout_seconds` in yaml: still **15** (chat default).

`run_end` was treated as **ok** with empty stdout/fallback text (otherwise COMSTAR would log `direct_agent_failed`).

---

## Session overlay agent (COMSTAR-owned YAML)

Repo: `overlays/comstar/agent_providers/voice_responder.yaml`

- id: `client.voice_responder`
- type: ollama / `qwen2.5:14b-instruct`
- `mcp_providers`: home_assistant, client.google_workspace
- skills: spoken_output, terminal_control_voice, home_assistant_voice, google_workspace_voice

HA skill points agents at:

- `sensor.irrigation_7d_*_minutes` (7d minutes per zone)
- Orbit `*_zone_history` / rain-delay switches  
  (vegetable garden, flower/back lawn, east lawn, front yard)

Verified in HA (examples):

- `sensor.irrigation_7d_tomato_minutes` → `0.0` min  
- `sensor.vegitable_garden_timer_tomato_zone_zone_history` → last run ~2026-07-27, `run_time: 3`

A correct spoken answer can be “no vegetable garden watering in the last 7 days; last tomato zone run was …”. Empty is wrong.

---

## Ada / AO environment (relevant)

```text
AGENTIC_EXECUTION_BACKEND=kubernetes
AGENTIC_SERVE_SESSION_OVERLAY=1
AGENTIC_SERVE_MCP_TUNNEL=1
AGENTIC_SPEECH_ENABLED=1
# advertised speech still :8090/:8091; COMSTAR overrides to :8093/:8092 via Reach 0.3
```

Engine pod (example): `agentic-orchestration/agentic-engine-bb8d6877d-7nmfv`  
Catalog path in container: `/app/tool/config/agent_providers`  
Host checkout: `/var/projects/agentic-orchestration/agentic-orchestration-tool`

`direct_agent` path: `orchestration/direct_agent.py` → CrewAI workflow → `sanitize_user_facing_prose(...)`.

---

## Hypotheses to check (in order)

1. **HA MCP tools fail or hang inside k8s worker**, Crew finishes with blank / tool-error prose that **sanitize strips to empty**.
2. **`home_assistant` MCP not fully available on the direct_agent worker** (stock catalog id works for planner but tool binding differs under k8s warm-pool).
3. **Agent never calls tools** for irrigation, invents nothing (spoken_output), returns whitespace → empty after sanitize.
4. **Timeouts inside AO/LiteLLM/MCP** shorter than 19s surface as empty ok rather than `run_end ok=false`.
5. **Progress chunks only on stderr**; useful answer stuck in a stream COMSTAR does not collect (less likely — simple chat worked via stdout).

---

## Suggested AO investigation steps

1. Reproduce with Reach/WS or HTTP `direct_agent` as user `zlatko` / session `comstar-zlatko` after registering COMSTAR overlay (or EXTRA catalog copy of `client.voice_responder`).
2. Capture full `chunk` stderr + stdout for the irrigation prompt; confirm whether tools were invoked and what HA returned.
3. Log pre- and post-`sanitize_user_facing_prose` in `run_direct_agent`.
4. Confirm k8s worker can reach the same HA MCP endpoint the engine uses for `home_assistant`.
5. If tools work but model returns empty: check CrewAI + ollama tool-calling for `qwen2.5:14b-instruct` with HA tool schemas.
6. Prefer a **non-empty failure** (`run_end ok=false` + error) over silent empty string when tools fail.

---

## COMSTAR changes already done (do not re-fix as AO work)

- Overlay TTL 86400 + refresh/reopen (`ensureReady`) — earlier “unknown `client.voice_responder`” overnight bug.
- Responding timeout floor 90s + SpeakFallback speaks even if state left Responding.
- Reverted local garden HA answer — must stay AO-only.
- HA voice skill text updated under `overlays/comstar/agent_skills/home_assistant_voice/instructions.md` (re-register overlay to pick up).

---

## Success criteria

- Same utterance via `direct_agent` + `home_assistant` returns a **short spoken non-empty** answer within ~30–60s (or clear `ok=false` error).
- COMSTAR logs `direct_agent_ok` and kiosk speaks the reply.
- No requirement for COMSTAR to special-case irrigation.

---

## Contacts / hosts

| Piece | Where |
|---|---|
| Pi bridge | `ssh comstar` (`192.168.89.34`), `journalctl --user -u comstar-bridge` |
| AO Reach | `10.0.10.16:8765` |
| COMSTAR repo | `/Users/zlatkolakisic/Projects/comstar` |
| AO tool tree | `/var/projects/agentic-orchestration/agentic-orchestration-tool` on Ada |
| Overlay agents | `comstar/overlays/comstar/` |
