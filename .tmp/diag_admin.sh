#!/usr/bin/env bash
set -euo pipefail
export HOME=/c/Users/Zlatko.Lakisic
export PATH=/d/Projects/comstar/.tmp/bin:/usr/bin:$PATH
ssh md-admin@192.168.89.34 bash -s <<'EOF'
set -euo pipefail
echo "=== units ==="
systemctl --user --no-pager is-active comstar-bridge || true
echo "=== ports ==="
ss -ltn | grep -E ':8778|:8781|:8780' || echo 'no match'
echo "=== admin env ==="
ls -la ~/.config/comstar/admin.env 2>/dev/null || echo 'no admin.env'
grep -E '^(COMSTAR_ADMIN|ADMIN)' ~/.config/comstar/admin.env 2>/dev/null | sed 's/=.*/=***/' || true
echo "=== yaml admin ==="
grep -A5 -E '^admin:|^dev:' /opt/comstar/src/config/comstar.yaml 2>/dev/null | head -40 || true
echo "=== local health ==="
curl -sS -m 3 http://127.0.0.1:8781/admin/health || echo "health fail"
echo
echo "=== listen bind ==="
journalctl --user -u comstar-bridge -n 80 --no-pager | grep -Ei 'admin|8781|bind|listen|error|fail' | tail -30 || true
EOF
