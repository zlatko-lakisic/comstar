#!/usr/bin/env bash
set -euo pipefail
export HOME=/c/Users/Zlatko.Lakisic
export PATH=/d/Projects/comstar/.tmp/bin:/usr/bin:$PATH
HOST=md-admin@192.168.89.34

ssh "$HOST" 'bash -s' <<'EOF'
set -euo pipefail
python3 - <<'PY'
import json, os, ssl, urllib.request, re, urllib.error

cfg=open("/opt/comstar/src/config/comstar.yaml").read()
base=re.search(r"base_url:\s*(\S+)", cfg).group(1).strip().strip('"').strip("'").rstrip("/")
token_m=re.search(r"^\s*token:\s*(\S+)", cfg, re.M)
token=(token_m.group(1).strip().strip('"').strip("'") if token_m else "")
print("has_token", bool(token), "len", len(token))
mat=os.path.expanduser("~/.local/share/comstar/ao-mtls")
ctx=ssl.create_default_context(cafile=os.path.join(mat,"ca.pem"))
ctx.load_cert_chain(certfile=os.path.join(mat,"cert.pem"), keyfile=os.path.join(mat,"key.pem"))

def get(path, headers=None):
  h={"Accept":"application/json"}
  if headers: h.update(headers)
  req=urllib.request.Request(base+path, headers=h)
  with urllib.request.urlopen(req, context=ctx, timeout=20) as res:
    return res.status, json.loads(res.read().decode())

candidates=[
  "/api/v1/admin/catalogs/agents",
  "/api/v1/admin/catalogs/agent_providers",
  "/api/v1/admin/catalogs/agent-providers",
  "/openapi.json",
  "/docs",
  "/api/v1/openapi.json",
  "/api/openapi.json",
  "/api/v1/admin/openapi.json",
]
auth_headers=[
  {},
  {"Authorization": f"Bearer {token}"} if token else {},
  {"X-API-Key": token} if token else {},
]
for path in candidates:
  for ah in auth_headers:
    label=path + ("+auth" if ah else "")
    try:
      status, d = get(path, ah or None)
      if isinstance(d, dict):
        items=d.get("items") or d.get("entries") or d.get("providers") or d.get("agents") or []
        print(label, status, "keys", sorted(d.keys())[:12], "n", len(items) if isinstance(items,list) else type(items).__name__)
        if isinstance(items, list) and items and isinstance(items[0], dict):
          print("  sample", [i.get("id") for i in items[:12]])
      elif isinstance(d, list):
        print(label, status, "list", len(d))
      else:
        print(label, status, type(d))
    except urllib.error.HTTPError as e:
      body=e.read()[:200]
      print(label, "HTTP", e.code, body[:120])
    except Exception as e:
      print(label, "ERR", e)
PY
EOF
