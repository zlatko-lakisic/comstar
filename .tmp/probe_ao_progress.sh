#!/usr/bin/env bash
set -euo pipefail
export HOME=/c/Users/Zlatko.Lakisic
export PATH=/d/Projects/comstar/.tmp/bin:/usr/bin:$PATH
HOST=md-admin@192.168.89.34
TOKEN=$(sed -n 's/.*token=//p' /d/Projects/comstar/.tmp/admin_url.txt | tr -d '\r\n')

for i in 1 2 3 4 5 6 7 8 9 10; do
  st=$(ssh "$HOST" 'systemctl --user is-active comstar-bridge || true')
  echo "bridge=$st ($i)"
  [[ "$st" == active ]] && break
  sleep 3
done

ssh "$HOST" bash -s <<EOF
set -euo pipefail
echo '=== files ==='
test -f /opt/comstar/src/terminal/kiosk/ao_activity.js && echo OK_AO_ACTIVITY
grep -n 'ao.progress\|createAoActivity' /opt/comstar/src/terminal/kiosk/index.html | head -8 || true
grep -n '0.72\|setThinking' /opt/comstar/src/terminal/kiosk/avatar.js | head -8 || true
grep -n 'railAoActivity\|createAoActivity' /opt/comstar/src/terminal/admin/components/emblem.js | head -8 || true
echo '=== journal (tail) ==='
journalctl --user -u comstar-bridge -n 30 --no-pager || true
echo '=== status ==='
curl -fsS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8781/admin/api/status | python3 -c 'import json,sys; d=json.load(sys.stdin); print("thinking", d.get("thinking")); print("ao_progress", d.get("ao_progress")); print("session_open", d.get("session_open"))'
echo '=== agents ==='
curl -fsS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8781/admin/api/agents | python3 -c 'import json,sys; d=json.load(sys.stdin); c=d.get("catalog") or {}; print("ok", d.get("ok"), "dyn", d.get("dynamic_planning")); print("enabled_agents", len(d.get("enabled_agent_ids") or [])); print("enabled_mcps", len(d.get("enabled_mcp_ids") or [])); print("enabled_skills", len(d.get("enabled_skill_ids") or [])); print("catalog_ok", c.get("ok"), "err", c.get("error")); print("cat_agents", len(c.get("agents") or [])); print("cat_mcps", len(c.get("mcps") or [])); print("cat_skills", len(c.get("skills") or [])); print("cat_harnesses", len(c.get("harnesses") or [])); print("sample", [a.get("id") for a in (c.get("agents") or [])[:5]])'
EOF
