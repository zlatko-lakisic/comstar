"""COMSTAR memory MCP — dial-back resident facts / recent turns.

See CONTRACTS §5 (`client.comstar_memory`). Bridge starts this on loopback via
`ComstarMcpBootstrap._maybeStartMemory` (disable with `COMSTAR_MEMORY_MCP=0`).

```bash
PYTHONPATH=mcp COMSTAR_MEMORY_URL=http://127.0.0.1:8792 \\
  COMSTAR_MEMORY_USERID=zlatko python3 -m memory_mcp --http --port 0
```

Tests: `python3 mcp/memory_mcp/test_server.py` and
`python3 -m unittest scripts.test_memory_mcp_e2e`.
"""
