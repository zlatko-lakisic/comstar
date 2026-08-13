#!/usr/bin/env bash
set -euo pipefail
export HOME=/c/Users/Zlatko.Lakisic
export PATH=/d/Projects/comstar/.tmp/bin:/usr/bin:$PATH
HOST=md-admin@192.168.89.34

ssh "$HOST" 'bash -s' <<'EOF'
set -euo pipefail
TOKEN=$(grep -E '^(COMSTAR_ADMIN_TOKEN|ADMIN_TOKEN|LAN_TOKEN)=' "$HOME/.config/comstar/admin.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r' | sed 's/^"//;s/"$//')
if [[ -z "$TOKEN" ]]; then
  echo "NO_TOKEN"
  exit 2
fi
echo "TOKEN_LEN=${#TOKEN}"
echo '=== health (no auth) ==='
curl -fsS "http://127.0.0.1:8781/admin/health" | python3 -c 'import json,sys; d=json.load(sys.stdin); print({k:d.get(k) for k in ["ok","thinking","ao_progress","session_open","state"]})'
echo '=== status query token ==='
curl -fsS "http://127.0.0.1:8781/admin/api/status?token=${TOKEN}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print({k:d.get(k) for k in ["ok","thinking","ao_progress","session_open","state"] if k in d or True}); print("has_ao", "ao_progress" in d, "has_thinking", "thinking" in d)'
echo '=== agents ==='
curl -fsS -H "x-comstar-lan-token: ${TOKEN}" "http://127.0.0.1:8781/admin/api/agents" | python3 -c 'import json,sys; d=json.load(sys.stdin); c=d.get("catalog") or {}; print("ok", d.get("ok"), "dyn", d.get("dynamic_planning")); print("enabled_agents", len(d.get("enabled_agent_ids") or [])); print("enabled_mcps", len(d.get("enabled_mcp_ids") or [])); print("enabled_skills", len(d.get("enabled_skill_ids") or [])); print("catalog_ok", c.get("ok"), "err", (str(c.get("error") or ""))[:160]); print("cat_agents", len(c.get("agents") or [])); print("cat_mcps", len(c.get("mcps") or [])); print("cat_skills", len(c.get("skills") or [])); print("cat_harnesses", len(c.get("harnesses") or [])); print("sample", [a.get("id") for a in (c.get("agents") or [])[:5]])'
EOF
