#!/usr/bin/env bash
set -euo pipefail
export HOME=/c/Users/Zlatko.Lakisic
export PATH=/d/Projects/comstar/.tmp/bin:/usr/bin:$PATH
HOST=md-admin@192.168.89.34

ssh "$HOST" 'bash -s' <<'EOF'
set -euo pipefail
# Probe common AO admin ports on Ada from Pi
python3 - <<'PY'
import socket, ssl, urllib.request, json
host="10.0.10.16"
ports=[80,443,3000,4200,8080,8443,8765,8766,8770,8780,8888,9000,9443]
for p in ports:
  s=socket.socket(); s.settimeout(0.6)
  try:
    s.connect((host,p)); s.close(); print("open", p)
  except Exception:
    pass

ctx=ssl._create_unverified_context()
for url in [
  "https://10.0.10.16:8765/api/v1/admin/web-auth",
  "https://10.0.10.16:8443/api/v1/admin/catalogs/agents",
  "https://10.0.10.16:8766/api/v1/admin/catalogs/agents",
  "http://10.0.10.16:4200/api/v1/admin/catalogs/agents",
  "http://10.0.10.16:8080/api/v1/admin/catalogs/agents",
]:
  try:
    req=urllib.request.Request(url, headers={"Accept":"application/json"})
    with urllib.request.urlopen(req, context=ctx, timeout=3) as res:
      body=res.read()[:200]
      print(url, res.status, body[:120])
  except Exception as e:
    print(url, type(e).__name__, e)
PY
EOF
