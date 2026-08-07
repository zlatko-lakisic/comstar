# Ada / AI-server MCP bring-up (ldap + vision)
#
# Status 2026-08-07 (Ada / nvr.mostardesigns.com as zlatko.lakisic):
#   - vision_mcp :8793 — user systemd `comstar-vision-mcp`
#   - directory_sidecar :8780 — `comstar-directory-sidecar`
#   - ldap_mcp :8794 — `comstar-ldap-mcp`
#   - secrets: ~/projects/comstar/config/{ldap,vision}.env (chmod 600)
#   - linger enabled so units survive logout
#
# Ops:
#   systemctl --user status comstar-directory-sidecar comstar-ldap-mcp comstar-vision-mcp
#   systemctl --user restart comstar-ldap-mcp
#
# Smoke:
#   curl -sS http://127.0.0.1:8780/health
#   curl -sS http://127.0.0.1:8794/mcp -H 'Content-Type: application/json' \
#     -H 'Accept: application/json, text/event-stream' \
#     -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
#
# Still needed (IPA admin / root on 10.0.10.10):
#   - Load docs/ldap/comstar.schema into FreeIPA (comstarFaceId / comstarPerson)
#   - Prefer dedicated bind uid=comstar-dir over mailserver
#   - Enroll faces with scripts/enroll_face.sh
#
# Frame source (vision) — already set on Ada:
#   COMSTAR_VISION_FRAME_URL=http://127.0.0.1:5000/api/front_door/latest.jpg
#   (Frigate on Ada; check_camera OK; who_is_present returns CPAI face result)
#   Prefer: systemctl --user restart comstar-vision-mcp
#   Fallback script sources config/vision.env: scripts/start-ada-mcps.sh
#
# AO env — MCP URLs must use letter-leading hosts (localhost), not raw IPs:
#   COMSTAR_LDAP_MCP_URL=http://localhost:8794/mcp
#   COMSTAR_VISION_MCP_URL=http://localhost:8793/mcp
# (http://10.0.10.16:8793/mcp mints illegal OpenAI tool names like
#  10_0_10_16_8793_mcp_who_visited and every vision turn fails.)
