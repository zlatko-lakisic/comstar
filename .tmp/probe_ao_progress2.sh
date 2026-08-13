#!/usr/bin/env bash
set -euo pipefail
export HOME=/c/Users/Zlatko.Lakisic
export PATH=/d/Projects/comstar/.tmp/bin:/usr/bin:$PATH
HOST=md-admin@192.168.89.34

ssh "$HOST" 'bash -s' <<'EOF'
set -euo pipefail
TOKEN=""
if [[ -f "$HOME/.config/comstar/admin.env" ]]; then
  # shellcheck disable=SC1090
  set -a
  # only pull token-ish vars without printing secrets in logs
  TOKEN=$(grep -E '^(COMSTAR_ADMIN_TOKEN|ADMIN_TOKEN|LAN_TOKEN)=' "$HOME/.config/comstar/admin.env" | head -1 | cut -d= -f2- | tr -d '\r' | sed 's/^"//;s/"$//')
  set +a
fi
if [[ -z "$TOKEN" ]]; then
  echo "NO_TOKEN_IN_ADMIN_ENV"
  ls -la "$HOME/.config/comstar/" || true
  exit 2
fi
echo "TOKEN_LEN=${#TOKEN}"
echo '=== status ==='
curl -fsS -H "Authorization: Bearer ${TOKEN}" "http://127.0.0.1:8781/admin/api/status" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("thinking", d.get("thinking")); print("ao_progress", d.get("ao_progress")); print("session_open", d.get("session_open")); print("keys", sorted([k for k in d.keys() if "ao" in k or "think" in k or "session" in k]))'
echo '=== agents ==='
curl -fsS -H "Authorization: Bearer ${TOKEN}" "http://127.0.0.1:8781/admin/api/agents" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); c=d.get("catalog") or {}; print("ok", d.get("ok"), "dyn", d.get("dynamic_planning")); print("enabled_agents", len(d.get("enabled_agent_ids") or [])); print("enabled_mcps", len(d.get("enabled_mcp_ids") or [])); print("enabled_skills", len(d.get("enabled_skill_ids") or [])); print("catalog_ok", c.get("ok"), "err", (c.get("error") or "")[:120]); print("cat_agents", len(c.get("agents") or [])); print("cat_mcps", len(c.get("mcps") or [])); print("cat_skills", len(c.get("skills") or [])); print("cat_harnesses", len(c.get("harnesses") or [])); print("sample", [a.get("id") for a in (c.get("agents") or [])[:5]])'
EOF
