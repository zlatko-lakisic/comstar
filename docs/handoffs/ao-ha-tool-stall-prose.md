# Handoff: HA MCP tool-stall prose still reaches COMSTAR voice

**For:** AO / agentic-orchestration on Ada  
**Date:** 2026-08-04  
**AO:** v1.28.1

## Symptom

`direct_agent` + `home_assistant` returns spoken ok text:

`Please provide the tool result for analysis.`

COMSTAR logs `direct_agent_ok` (~15s). Irrigation / soil questions also often
return “I do not have access…” in ~8s without tools.

## Ask

1. Treat `please provide the tool result` / `tool result for analysis` as
   `looks_like_unusable_crew_answer` (patched in COMSTAR’s vendor AO tree;
   needs Ada hotfix/release).
2. Confirm HA MCP tool results are fed back into the CrewAI loop on k8s workers
   (stall suggests call started but observation never resumed).

## COMSTAR mitigation

Irrigation/watering intents now read Assist-exposed sensors via HA agent HTTP
(same pattern as torrents) so hallway voice stays useful while the tool loop is
broken.
