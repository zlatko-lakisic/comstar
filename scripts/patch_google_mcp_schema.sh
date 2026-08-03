#!/usr/bin/env bash
# Soften mcp-server-google-workspace schemas CrewAI rejects (union types).
set -euo pipefail
JS="${1:-$HOME/.local/node_modules/mcp-server-google-workspace/dist/index.js}"
[[ -f "$JS" ]] || { echo "missing $JS"; exit 2; }
python3 - "$JS" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
n = t.count("type: ['string', 'array']") + t.count('type: ["string", "array"]')
t2 = t.replace("type: ['string', 'array']", "type: 'string'").replace(
    'type: ["string", "array"]', 'type: "string"'
)
if t2 != t:
  p.write_text(t2)
print(f'patched {n} union schema(s) in {p}')
else:
  print(f'already clean: {p}')
PY
