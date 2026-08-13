#!/usr/bin/env bash
set -euo pipefail
export HOME=/c/Users/Zlatko.Lakisic
export PATH=/d/Projects/comstar/.tmp/bin:/usr/bin:$PATH
TOKEN=$(ssh md-admin@192.168.89.34 "grep '^COMSTAR_ADMIN_TOKEN=' ~/.config/comstar/admin.env | cut -d= -f2-")
echo "=== GET /admin/api/agents ==="
curl -sS -m 8 -H "X-Comstar-Lan-Token: $TOKEN" "http://192.168.89.34:8781/admin/api/agents" | head -c 800
echo
echo
echo "=== POST configure ==="
curl -sS -m 8 -H "X-Comstar-Lan-Token: $TOKEN" -H 'Content-Type: application/json' \
  -d '{"action":"configure","dynamic_planning":true}' \
  "http://192.168.89.34:8781/admin/api/agents" | head -c 400
echo
echo
echo "=== agents.js path check ==="
grep -n "api/agents\|admin/api" /d/Projects/comstar/terminal/admin/components/agents.js | head
ssh md-admin@192.168.89.34 "grep -n \"api.get\\|api.post\" /opt/comstar/src/terminal/admin/components/agents.js | head"
