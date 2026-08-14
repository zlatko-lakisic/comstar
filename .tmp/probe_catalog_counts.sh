#!/usr/bin/env bash
set -euo pipefail
export HOME=/c/Users/Zlatko.Lakisic
export PATH=/d/Projects/comstar/.tmp/bin:/usr/bin:$PATH
HOST=md-admin@192.168.89.34

ssh "$HOST" 'bash -s' <<'EOF'
set -euo pipefail
python3 - <<'PY'
import json, os, ssl, urllib.request, re

cfg=open("/opt/comstar/src/config/comstar.yaml").read()
m=re.search(r"base_url:\s*(\S+)", cfg)
base=(m.group(1).strip().strip('"').strip("'") if m else "").rstrip("/")
mat=os.path.expanduser("~/.local/share/comstar/ao-mtls")
ctx=ssl.create_default_context(cafile=os.path.join(mat,"ca.pem"))
ctx.load_cert_chain(certfile=os.path.join(mat,"cert.pem"), keyfile=os.path.join(mat,"key.pem"))

def get(path):
  req=urllib.request.Request(base+path, headers={"Accept":"application/json"})
  with urllib.request.urlopen(req, context=ctx, timeout=20) as res:
    return json.loads(res.read().decode())

d=get("/api/v1/catalog")
print("counts", json.dumps(d.get("counts"), indent=2))
print("enableFields", d.get("enableFields"))
print("secretLabels keys", list((d.get("secretLabels") or {}).keys())[:30])
print("agents", len(d["agents"]), "mcps", len(d["mcps"]), "skills", len(d["skills"]), "harnesses", len(d["harnesses"]))
# try more query variants from counts clues
for path in [
  "/api/v1/catalog?availability=all",
  "/api/v1/catalog?status=all",
  "/api/v1/catalog?includeUnavailable=1",
  "/api/v1/catalog?unavailable=1",
  "/api/v1/catalog?gate=off",
  "/api/v1/catalog?filter=none",
  "/api/v1/catalog?mode=full",
  "/api/v1/catalog?view=full",
  "/api/v1/catalog?stock=1",
  "/api/v1/catalog?kinds=agents,mcps,skills,harnesses&availability=all",
  "/api/v1/providers",
  "/api/v1/agent_providers",
  "/api/v1/agents",
  "/api/v1/config/agent_providers",
]:
  try:
    x=get(path)
    if isinstance(x, dict):
      print(path, "keys", sorted(x.keys())[:15], "agents", len(x.get("agents") or x.get("items") or x.get("providers") or []))
      if "counts" in x: print("  counts", x["counts"])
    elif isinstance(x, list):
      print(path, "list", len(x))
  except Exception as e:
    print(path, "ERR", e)
PY
EOF
