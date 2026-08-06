# COMSTAR LDAP planner MCP

Wraps `mcp/directory_sidecar` for AO planner tools:

- `lookup_user` — GET `{DIR}/v1/lookup?uid=`
- `list_comstar_users` — GET `{DIR}/v1/users`

```bash
cd mcp
COMSTAR_DIRECTORY_URL=http://10.0.10.16:8780 \
  COMSTAR_MCP_HTTP=1 python -m ldap_mcp --http --port 8794
```

Session open must **not** depend on this MCP (ADR 0005). Overlay agents that
use directory tools should set `guest_allowed: false`.
