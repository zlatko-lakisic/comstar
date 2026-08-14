#!/usr/bin/env bash
set -euo pipefail
export HOME=/c/Users/Zlatko.Lakisic
export PATH=/d/Projects/comstar/.tmp/bin:/usr/bin:$PATH
HOST=md-admin@192.168.89.34
ssh "$HOST" 'bash -s' <<'EOF'
python3 - <<'PY'
import json,ssl,urllib.request,os
mat=os.path.expanduser("~/.local/share/comstar/ao-mtls")
ctx=ssl.create_default_context(cafile=os.path.join(mat,"ca.pem"))
ctx.load_cert_chain(certfile=os.path.join(mat,"cert.pem"), keyfile=os.path.join(mat,"key.pem"))
# health without mtls
print("HEALTH", urllib.request.urlopen("https://10.0.10.16:8765/health", context=ssl._create_unverified_context(), timeout=5).read().decode())
PY
EOF
