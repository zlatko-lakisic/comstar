# Ada / AI-server MCP bring-up (ldap + vision) — needs SSH + secrets.
#
# Blockers from a Mac without Ada SSH keys (2026-08-06):
#   - 10.0.10.16:22 open but md-admin/zlatko → publickey denied
#   - :8780 directory_sidecar, :8793 vision_mcp, :8794 ldap_mcp all closed
#
# Once you can SSH as the AO host user:
#
#   export COMSTAR_SRC=/var/projects/comstar   # or clone path
#   export AO_TOOL=/var/projects/agentic-orchestration/agentic-orchestration-tool
#
#   # FreeIPA bind (from docs/ldap — not committed)
#   export COMSTAR_LDAP_URL=… COMSTAR_LDAP_BIND_DN=… COMSTAR_LDAP_BIND_PASSWORD=…
#   export COMSTAR_LDAP_BASE_DN=…
#
#   cd "$COMSTAR_SRC/mcp"
#   python -m directory_sidecar &          # :8780
#   COMSTAR_DIRECTORY_URL=http://127.0.0.1:8780 \
#     COMSTAR_MCP_HTTP=1 python -m ldap_mcp --http --host 127.0.0.1 --port 8794 &
#
#   export COMSTAR_CPAI_URL=http://127.0.0.1:32168
#   export COMSTAR_VISION_FRAME_URL=…      # or COMSTAR_VISION_FRAME=/path/latest.jpg
#   COMSTAR_MCP_HTTP=1 python -m vision_mcp --http --host 127.0.0.1 --port 8793 &
#
#   cp "$COMSTAR_SRC/overlays/comstar/mcp_providers/ldap_directory.yaml" \
#      "$AO_TOOL/config/mcp_providers/"
#   cp "$COMSTAR_SRC/overlays/comstar/mcp_providers/vision_comstar.yaml" \
#      "$AO_TOOL/config/mcp_providers/"
#
#   # AO .env / k8s secret:
#   #   COMSTAR_LDAP_MCP_URL=http://127.0.0.1:8794/mcp
#   #   COMSTAR_VISION_MCP_URL=http://127.0.0.1:8793/mcp
#   # restart AO engine / coordinator so catalogs reload
#
# Smoke:
#   curl -sS http://127.0.0.1:8794/mcp -H 'Content-Type: application/json' \
#     -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
