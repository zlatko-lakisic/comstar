#!/usr/bin/env bash
set -euo pipefail
export HOME=/c/Users/Zlatko.Lakisic
export PATH=/d/Projects/comstar/.tmp/bin:/usr/bin:$PATH

echo "=== from PC to Pi :8781 ==="
curl -sS -m 5 -o /tmp/admin_body.txt -w "http=%{http_code}\n" http://192.168.89.34:8781/admin/health || echo "curl_fail"
head -c 200 /tmp/admin_body.txt 2>/dev/null; echo

echo "=== admin UI without token ==="
curl -sS -m 5 -o /tmp/admin_ui.txt -w "http=%{http_code}\n" http://192.168.89.34:8781/admin/ || echo "curl_fail"
head -c 120 /tmp/admin_ui.txt 2>/dev/null; echo

TOKEN=$(ssh md-admin@192.168.89.34 "grep '^COMSTAR_ADMIN_TOKEN=' ~/.config/comstar/admin.env | cut -d= -f2-")
echo "=== admin UI with token (len=${#TOKEN}) ==="
curl -sS -m 5 -o /tmp/admin_tok.txt -w "http=%{http_code}\n" \
  "http://192.168.89.34:8781/admin/?token=${TOKEN}" || echo "curl_fail"
head -c 200 /tmp/admin_tok.txt 2>/dev/null; echo

# Persist URL for user (local only)
printf 'http://192.168.89.34:8781/admin/?token=%s\n' "$TOKEN" > /d/Projects/comstar/.tmp/admin_url.txt
echo "wrote .tmp/admin_url.txt"
