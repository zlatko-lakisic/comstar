# vision MCP

Hosted MCP wrapping CodeProject.AI (`who_is_present`, `describe_view`,
`check_camera`) plus Frigate visitor history (`list_person_visits`,
`describe_visit`, `who_visited`). See `docs/CONTRACTS.md` §5.

## Run

```bash
# On Ada (or any host that can reach CPAI + Frigate):
export COMSTAR_CPAI_URL=http://127.0.0.1:32168
export COMSTAR_VISION_FRAME_URL=http://127.0.0.1:5000/api/front_door/latest.jpg
export COMSTAR_FRIGATE_URL=http://127.0.0.1:5000
# Prefer HA LLM Vision for unknown person descriptions (same as driveway alerts):
export HOME_ASSISTANT_URL=https://ha.example.com
export HOME_ASSISTANT_TOKEN=...
# Fallbacks if HA fails: OPENAI_API_KEY, then local Ollama moondream
COMSTAR_MCP_HTTP=1 python -m vision_mcp --http --host 127.0.0.1 --port 8793
```

Register with AO as a plain HTTP MCP (co-located with the daemon — **not**
the Pi reverse tunnel).

## Frame source (live tools)

| env | meaning |
|---|---|
| `COMSTAR_VISION_FRAME_URL` | HTTP GET (preferred when a snapshot endpoint exists) |
| `COMSTAR_VISION_FRAME` | Local file path refreshed by a sidecar |
| `image_b64` tool arg | Test override (not in the public schema) |

## Visitor history

| env | meaning |
|---|---|
| `COMSTAR_FRIGATE_URL` | Frigate API (default `http://127.0.0.1:5000`) |
| `COMSTAR_VISIT_CAMERA` | Default camera (default `driveway`) |
| `COMSTAR_TZ` | Local midnight for `since=today` (default `America/New_York`) |
| `COMSTAR_VISIT_MAX_UNKNOWN` | Max LLM describes per `who_visited` (default 5) |
| `HOME_ASSISTANT_URL` / `HOME_ASSISTANT_TOKEN` | HA `llmvision.image_analyzer` (gpt-4o-mini) |
| `OPENAI_API_KEY` | Fallback multimodal describe |
| `COMSTAR_OLLAMA_URL` / `COMSTAR_OLLAMA_VISION_MODEL` | Local fallback (default moondream) |

`who_visited` is the voice entry point for “who was in my driveway today”.

## Smoke

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  | python -m vision_mcp

curl -sS http://127.0.0.1:8793/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"who_visited","arguments":{"camera":"driveway","since":"today"}}}'
```
