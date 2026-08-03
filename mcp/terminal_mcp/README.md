# terminal MCP

Tunnelled MCP on the Pi (`client.terminal` / `tunnel://session-mcp/terminal`).

Exposes display/tone stubs plus **sleep** and **speaker volume** tools that call
bridge loopback HTTP (`http://127.0.0.1:8776/control/...`). See CONTRACTS §5 and
ADR 0004.

Preferred transport: **streamable HTTP** (`python -m terminal_mcp --http`) so the
bridge can attach without Node/`mcp-proxy`. Stdio NDJSON still works for local tests.
