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
base=re.search(r"base_url:\s*(\S+)", cfg).group(1).strip().strip('"').strip("'").rstrip("/")
mat=os.path.expanduser("~/.local/share/comstar/ao-mtls")
ctx=ssl.create_default_context(cafile=os.path.join(mat,"ca.pem"))
ctx.load_cert_chain(certfile=os.path.join(mat,"cert.pem"), keyfile=os.path.join(mat,"key.pem"))
req=urllib.request.Request(base+"/openapi.json", headers={"Accept":"application/json"})
with urllib.request.urlopen(req, context=ctx, timeout=20) as res:
  spec=json.loads(res.read().decode())
paths=spec.get("paths") or {}
for p, methods in sorted(paths.items()):
  if any(k in p.lower() for k in ("catalog", "agent", "provider", "mcp", "skill", "harness", "capabilit")):
    print(p, ",".join(sorted(methods.keys())))
    for m, meta in methods.items():
      if m.startswith("x"): continue
      params=meta.get("parameters") or []
      for prm in params:
        if prm.get("in")=="query":
          schema=prm.get("schema") or {}
          print(f"  query {prm.get('name')} enum={schema.get('enum')} default={schema.get('default')} desc={(prm.get('description') or '')[:80]}")
PY
EOF
