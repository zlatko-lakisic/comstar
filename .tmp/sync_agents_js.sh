#!/usr/bin/env bash
set -euo pipefail
export HOME=/c/Users/Zlatko.Lakisic
export PATH=/d/Projects/comstar/.tmp/bin:/usr/bin:$PATH
HOST=md-admin@192.168.89.34
rsync -az /d/Projects/comstar/terminal/admin/components/agents.js \
  "$HOST:/opt/comstar/src/terminal/admin/components/agents.js"
ssh "$HOST" 'grep -n "api.get\|api.post\|await api(" /opt/comstar/src/terminal/admin/components/agents.js | head -20'
