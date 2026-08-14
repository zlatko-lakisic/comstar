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
mat=os.path.expanduser("~/.local/share/comstar/ao-mtls")
ctx=ssl.create_default_context(cafile=os.path.join(mat,"ca.pem"))
ctx.load_cert_chain(certfile=os.path.join(mat,"cert.pem"), keyfile=os.path.join(mat,"key.pem"))

def get(path, headers=None):
  h={"Accept":"application/json"}
  if headers: h.update(headers)
  req=urllib.request.Request(base+path, headers=h)
  with urllib.request.urlopen(req, context=ctx, timeout=20) as res:
    return res.status, json.loads(res.read().decode())

# dump catalog agents fully + openapi path detail for /api/v1/catalog
status, d = get("/api/v1/catalog")
print(json.dumps({"agents": d["agents"], "counts": d["counts"], "secretLabels": d.get("secretLabels")}, indent=2)[:4000])

status, spec = get("/openapi.json")
cat=spec["paths"]["/api/v1/catalog"]["get"]
print("CATALOG_OPENAPI", json.dumps(cat, indent=2)[:2500])

# enumerate all openapi paths containing admin
for p in sorted(spec["paths"]):
  if "admin" in p:
    print("ADMIN_PATH", p, ",".join(spec["paths"][p].keys()))

# try topology / components that might list providers
for path in ["/api/v1/topology", "/api/v1/admin/topology", "/api/v1/status", "/api/v1/health", "/api/v1/capabilities", "/api/v1/effective-config"]:
  try:
    st, x = get(path)
    if isinstance(x, dict):
      print(path, st, sorted(x.keys())[:20])
    else:
      print(path, st, type(x))
  except urllib.error.HTTPError as e:
    print(path, "HTTP", e.code)
PY
EOF
