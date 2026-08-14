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

paths=[
  "/api/v1/catalog",
  "/api/v1/catalog?include_disabled=1",
  "/api/v1/catalog?enabled=all",
  "/api/v1/catalog?ready=false",
  "/api/v1/admin/catalogs/agents",
  "/api/v1/admin/catalogs/mcp",
  "/api/v1/admin/catalogs/skills",
  "/api/v1/admin/catalogs/harnesses",
]
for path in paths:
  url=base+path
  try:
    req=urllib.request.Request(url, headers={"Accept":"application/json"})
    with urllib.request.urlopen(req, context=ctx, timeout=20) as res:
      d=json.loads(res.read().decode())
      if isinstance(d, dict):
        agents=d.get("agents") or d.get("items") or d.get("entries") or d.get("catalog") or []
        if isinstance(agents, dict):
          agents=list(agents.values()) if agents else []
        print(path, "HTTP", res.status, "top_keys", sorted(d.keys())[:20])
        if isinstance(agents, list):
          print("  list_len", len(agents))
          if agents and isinstance(agents[0], dict):
            print("  item_keys", sorted(agents[0].keys())[:20])
            print("  sample_ids", [a.get("id") or a.get("name") for a in agents[:10]])
        # sometimes items nested
        for k in ("items","entries","agents","results"):
          v=d.get(k)
          if isinstance(v, list):
            print("  ", k, len(v))
      elif isinstance(d, list):
        print(path, "HTTP", res.status, "list", len(d))
        if d and isinstance(d[0], dict):
          print("  item_keys", sorted(d[0].keys())[:20])
          print("  sample", [x.get("id") or x.get("name") for x in d[:10]])
  except Exception as e:
    print(path, "ERR", type(e).__name__, e)
PY
EOF
