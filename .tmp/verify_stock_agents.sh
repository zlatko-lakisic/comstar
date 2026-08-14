#!/usr/bin/env bash
set -euo pipefail
export HOME=/c/Users/Zlatko.Lakisic
export PATH=/d/Projects/comstar/.tmp/bin:/usr/bin:$PATH
HOST=md-admin@192.168.89.34

ssh "$HOST" 'bash -s' <<'EOF'
set -euo pipefail
for i in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS http://127.0.0.1:8781/admin/health >/dev/null 2>&1; then break; fi
  sleep 2
done
TOKEN=$(grep -E '^(COMSTAR_ADMIN_TOKEN|ADMIN_TOKEN|LAN_TOKEN)=' "$HOME/.config/comstar/admin.env" | head -1 | cut -d= -f2- | tr -d '\r' | sed 's/^"//;s/"$//')
curl -fsS -H "x-comstar-lan-token: ${TOKEN}" http://127.0.0.1:8781/admin/api/agents \
 | python3 -c 'import json,sys; d=json.load(sys.stdin); c=d.get("catalog") or {}; ag=c.get("agents") or []; print("ok", c.get("ok"), "live", c.get("live_agent_count"), "stock", c.get("stock_agent_count"), "agents", len(ag)); print("available", sum(1 for a in ag if a.get("available") or a.get("onAo"))); print("gpt", [a.get("id") for a in ag if str(a.get("id","")).startswith("gpt")]); print("sample", [a.get("id") for a in ag[:6]])'
EOF
