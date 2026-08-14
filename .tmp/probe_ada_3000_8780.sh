#!/usr/bin/env bash
set -euo pipefail
export HOME=/c/Users/Zlatko.Lakisic
export PATH=/d/Projects/comstar/.tmp/bin:/usr/bin:$PATH
HOST=md-admin@192.168.89.34

ssh "$HOST" 'bash -s' <<'EOF'
set -euo pipefail
python3 - <<'PY'
import json, ssl, urllib.request, urllib.error

ctx=ssl._create_unverified_context()

def try_url(url, headers=None):
  h={"Accept":"application/json"}
  if headers: h.update(headers)
  try:
    req=urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, context=ctx, timeout=5) as res:
      body=res.read()
      ct=res.headers.get("content-type","")
      print(url, res.status, ct, body[:180])
      if "json" in ct:
        d=json.loads(body)
        if isinstance(d, dict):
          items=d.get("items") or d.get("entries") or d.get("providers") or d.get("agents")
          if isinstance(items, list):
            print("  items", len(items), "sample", [i.get("id") for i in items[:8] if isinstance(i, dict)])
        elif isinstance(d, list):
          print("  list", len(d))
  except urllib.error.HTTPError as e:
    print(url, "HTTP", e.code, e.read()[:120])
  except Exception as e:
    print(url, type(e).__name__, e)

bases=["http://10.0.10.16:3000","http://10.0.10.16:8780","https://10.0.10.16:3000","https://10.0.10.16:8780","https://10.0.10.16:8765"]
paths=["/","/api/v1/admin/catalogs/agents","/api/v1/catalog","/api/v1/admin/web-auth","/health","/api/health"]
for b in bases:
  for p in paths:
    try_url(b+p)
PY
EOF
