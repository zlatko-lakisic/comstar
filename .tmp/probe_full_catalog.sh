#!/usr/bin/env bash
set -euo pipefail
export HOME=/c/Users/Zlatko.Lakisic
export PATH=/d/Projects/comstar/.tmp/bin:/usr/bin:$PATH
HOST=md-admin@192.168.89.34

ssh "$HOST" 'bash -s' <<'EOF'
set -euo pipefail
# Find orchestration base URL from comstar.yaml
BASE=$(python3 - <<'PY'
import re
p="/opt/comstar/src/config/comstar.yaml"
text=open(p).read()
m=re.search(r"base_url:\s*(\S+)", text)
print(m.group(1).strip().strip('"').strip("'") if m else "")
PY
)
echo "BASE=$BASE"
# Try catalog with common query variants via curl from Pi (mTLS may be needed)
python3 - <<'PY'
import json, os, ssl, urllib.request, pathlib, re

cfg=open("/opt/comstar/src/config/comstar.yaml").read()
m=re.search(r"base_url:\s*(\S+)", cfg)
base=(m.group(1).strip().strip('"').strip("'") if m else "").rstrip("/")
print("base", base)

# material dir
home=os.path.expanduser("~")
mat=os.path.join(home, ".local/share/comstar/ao-mtls")
cert=os.path.join(mat, "client.crt")
key=os.path.join(mat, "client.key")
ca=os.path.join(mat, "ca.crt")
print("mtls_files", os.path.exists(cert), os.path.exists(key), os.path.exists(ca))

ctx=ssl.create_default_context()
if os.path.exists(ca):
    ctx.load_verify_locations(ca)
if os.path.exists(cert) and os.path.exists(key):
    ctx.load_cert_chain(certfile=cert, keyfile=key)

variants=[
  "/api/v1/catalog",
  "/api/v1/catalog?kinds=agents",
  "/api/v1/catalog?include=all",
  "/api/v1/catalog?all=1",
  "/api/v1/catalog?enabled=false",
  "/api/v1/catalog?include_disabled=1",
  "/api/v1/catalog?includeDisabled=true",
  "/api/v1/catalog?scope=stock",
  "/api/v1/catalog?filter=all",
]
for path in variants:
  url=base+path
  try:
    req=urllib.request.Request(url, headers={"Accept":"application/json"})
    with urllib.request.urlopen(req, context=ctx, timeout=12) as res:
      body=res.read().decode()
      d=json.loads(body)
      agents=d.get("agents") or []
      print(path, "HTTP", res.status, "agents", len(agents), "mcps", len(d.get("mcps") or []), "keys", sorted(d.keys())[:12])
      if agents and len(agents)<=5:
        print("  ids", [a.get("id") for a in agents])
      elif agents:
        print("  sample", [a.get("id") for a in agents[:8]], "... total", len(agents))
        # print first agent keys for schema clues
        print("  agent_keys", sorted((agents[0] or {}).keys()))
  except Exception as e:
    print(path, "ERR", type(e).__name__, e)
PY
EOF
