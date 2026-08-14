#!/usr/bin/env bash
set -euo pipefail
export HOME=/c/Users/Zlatko.Lakisic
export PATH=/d/Projects/comstar/.tmp/bin:/usr/bin:$PATH
HOST=md-admin@192.168.89.34

ssh "$HOST" 'bash -s' <<'EOF'
set -euo pipefail
echo '=== mtls material ==='
find "$HOME/.local/share/comstar" -maxdepth 3 -type f 2>/dev/null | head -40
grep -E 'material_dir|mtls|base_url' /opt/comstar/src/config/comstar.yaml || true
TOKEN=$(grep -E '^(COMSTAR_ADMIN_TOKEN|ADMIN_TOKEN|LAN_TOKEN)=' "$HOME/.config/comstar/admin.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r' | sed 's/^"//;s/"$//')
echo '=== agents catalog via admin api ==='
curl -fsS -H "x-comstar-lan-token: ${TOKEN}" "http://127.0.0.1:8781/admin/api/agents" \
 | python3 -c 'import json,sys; d=json.load(sys.stdin); c=d.get("catalog") or {}; print("catalog_ok", c.get("ok"), "agents", len(c.get("agents") or []), "ids", [a.get("id") for a in (c.get("agents") or [])]); print("status_agents", len(d.get("agents") or []), [a.get("id") for a in (d.get("agents") or [])][:20])'
EOF
