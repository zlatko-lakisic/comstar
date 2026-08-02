# AO handoff — CrewAI trace prompt blocks COMSTAR `direct_agent`

**From:** COMSTAR Cursor session (Pi kiosk / Reach client)  
**Date:** 2026-08-02  
**Host:** `10.0.10.16` (SSH `zlatko.lakisic@10.0.10.16`)  
**Engine:** k3s `agentic-orchestration` / Deployment `agentic-engine` / image `v1.27.4` / hostPort **8765**  
**Constraint from COMSTAR owner:** diagnose freely; **do not change AO/reach without explicit approval** (this doc is the ask to fix on AO).

---

## Symptom (COMSTAR side)

Spoken follow-up after greeter reaches AO, then fails:

```text
TimeoutException: direct_agent timed out for client.voice_responder (<questionId>)
```

- COMSTAR `orchestration.timeout_seconds`: **15**
- Path: Pi bridge → Reach WS `direct_agent` → AO engine → CrewAI → Ollama `qwen2.5:14b-instruct`
- Agent ids are **session overlays** (`client.greeter`, `client.voice_responder`), not stock catalog. REST `POST /api/v1/direct-agent` without a live WS overlay correctly returns `unknown agent_provider_id`.
- Greeter still “works” on COMSTAR because greetings are **cached** after one success; voice has no equivalent cache.

Verified inject (2026-08-02 ~00:50 local):

```text
direct_agent Calling voice agent text=what time is it
…15s…
direct_agent_failed TimeoutException: … client.voice_responder (comstar-1785646234692631)
```

---

## Root cause (AO engine)

CrewAI inside the engine pod blocks **after** the crew finishes on an interactive stdin prompt:

```text
(progress) Ensuring Ollama for session agent 'client.voice_responder' (qwen2.5:14b-instruct)…
Would you like to view your execution traces? [y/N] (20s timeout):
```

That **20s** prompt outlasts COMSTAR’s **15s** client timeout, so Reach abandons the turn even if AO later returns.

Source (in engine venv):

- `crewai/events/listeners/tracing/utils.py` → `prompt_user_for_trace_viewing(timeout_seconds=20)`
- `crewai/events/listeners/tracing/first_time_trace_handler.py` → `handle_execution_completion()`
- `crewai/events/listeners/tracing/trace_listener.py` — `FirstTimeTraceHandler` is created **once** per process; `initialize_for_first_time_user()` sets `is_first_time` once and **never clears it**, so every subsequent crew completion re-prompts for the life of the pod.

Preference file observed in running pod:

```text
/root/.local/share/tool/.crewai_user.json
```

```json
{
  "first_execution_done": true,
  "trace_consent": false,
  ...
}
```

Even with consent declined, the **already-running** listener still prompts because `is_first_time` stayed `true`. That path is also ephemeral (container local `/root/.local`) — lost on pod recreate unless env/volume makes it durable.

Engine flags already OK for COMSTAR overlays:

- `AGENTIC_SERVE_SESSION_OVERLAY=1`
- `AGENTIC_SERVE_MCP_TUNNEL=1`

Secondary (not the 15s timeout): `/health` → `resident.keepaliveOk: false` / log `(engine) ollama keep-alive: ping failed`. Direct Ollama generate on host still works. Worth a follow-up, not the primary bug.

---

## What COMSTAR expects from AO

1. **No interactive prompts** in `python -m orchestration.serve` / engine daemon path (no TTY).
2. `direct_agent` for session overlay agents returns within a few seconds when the model is warm (historical COMSTAR baseline ~0.85–1.0s for greeter/voice on this host).
3. Preference / disable must **survive pod restarts**.

---

## Recommended AO fixes (pick durable + immediate)

### A. Immediate (validate)

Restart `agentic-engine` so the process re-inits with existing declined preference:

```bash
kubectl -n agentic-orchestration rollout restart deploy/agentic-engine
kubectl -n agentic-orchestration rollout status deploy/agentic-engine
```

Then confirm logs no longer show `Would you like to view your execution traces?` on a WS `direct_agent`.

### B. Durable (recommended)

On `agentic-engine` (or `agentic-orchestrator-env` secret):

| Env | Why |
|-----|-----|
| `CREWAI_TESTING=true` | CrewAI skips auto-collect + `prompt_user_for_trace_viewing` |
| and/or bake/mount `.crewai_user.json` with `first_execution_done: true`, `trace_consent: false` on a durable volume | Survives recreate without relying on TESTING |

`CREWAI_TRACING_ENABLED=false` alone is **not** enough for the first-time auto-collect / view-prompt path when `first_execution_done` is unset.

Better long-term: in AO serve/bootstrap, call CrewAI’s `set_suppress_tracing_messages(True)` / force non-interactive tracing off for daemon mode so site-packages behavior cannot block HTTP/WS handlers.

### C. Do **not** ask COMSTAR to “fix” by only raising timeout

Raising above 20s would still add ~20s of dead air per turn while the prompt waits.

---

## How to verify (AO)

1. Engine logs clean of the traces prompt during `client.*` direct_agent.
2. From a Reach client (or COMSTAR Pi with session open), `direct_agent` `client.voice_responder` text `what time is it` with MCP ids `home_assistant` (+ optional `media_audio_transcribe`) completes **&lt; 15s**, ideally ~1–3s warm.
3. `/health` still `ok`; ideally `keepaliveOk: true` after keepalive follow-up.

COMSTAR overlays live on the Pi at:

```text
/opt/comstar/src/overlays/comstar/agent_providers/{greeter,voice_responder}.yaml
```

Repo copies: `comstar/overlays/comstar/agent_providers/`. Model: `qwen2.5:14b-instruct`, `ollama_host: workflow`.

---

## Ops crumbs

```bash
# Pod
kubectl -n agentic-orchestration get pods -l app.kubernetes.io/name=agentic-engine
# or by name pattern agentic-engine-*

# Recent stall evidence
kubectl -n agentic-orchestration logs deploy/agentic-engine --tail=200 | grep -E 'Would you like|voice_responder|keepalive'

# Preference inside pod
kubectl -n agentic-orchestration exec deploy/agentic-engine -- cat /root/.local/share/tool/.crewai_user.json

# Host Ollama (engine uses OLLAMA_API_BASE=http://host.k3s.internal:11434)
curl -sS http://127.0.0.1:11434/api/ps
```

Tool root on host (hostPath): `/var/projects/agentic-orchestration` → `/app/tool` in pod.

---

## Out of scope for this handoff

- COMSTAR VAD/STT/mic (separate; inject path already proved AO timeout independently).
- Reach library changes.
- Adding `client.*` agents to the static catalog (session overlay is the intended path).

---

## Ask

Please implement **B** (durable non-interactive CrewAI in engine) and apply **A** so the live pod stops blocking. Reply when greeter/voice `direct_agent` no longer emits the traces prompt and a warm voice turn returns under 15s — COMSTAR will retest end-to-end.
