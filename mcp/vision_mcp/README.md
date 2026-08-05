# vision MCP

Hosted MCP wrapping CodeProject.AI (`who_is_present`, `describe_view`,
`check_camera`). See `docs/CONTRACTS.md` §5.

## Run

```bash
# On Ada (or any host that can reach CPAI), with a frame source:
export COMSTAR_CPAI_URL=http://127.0.0.1:32168
export COMSTAR_VISION_FRAME=/path/to/latest.jpg   # or COMSTAR_VISION_FRAME_URL=...
COMSTAR_MCP_HTTP=1 python -m vision_mcp --http --host 127.0.0.1 --port 8793
```

Register with AO as a plain HTTP MCP (co-located with the daemon — **not**
the Pi reverse tunnel). Until AO catalogs this provider, tools are available
for local smoke tests only.

## Frame source

Attention/face recognition on the Pi already runs in-process via the bridge
vision poller. This MCP is for **orchestrator-side** “who’s there?” queries.
It needs a JPEG:

| env | meaning |
|---|---|
| `COMSTAR_VISION_FRAME_URL` | HTTP GET (preferred when a snapshot endpoint exists) |
| `COMSTAR_VISION_FRAME` | Local file path refreshed by a sidecar |
| `image_b64` tool arg | Test override (not in the public schema) |

## Smoke

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  | python -m vision_mcp
```
