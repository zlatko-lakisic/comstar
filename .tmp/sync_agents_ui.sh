#!/usr/bin/env bash
set -euo pipefail
export HOME=/c/Users/Zlatko.Lakisic
export PATH=/d/Projects/comstar/.tmp/bin:/usr/bin:$PATH
HOST=md-admin@192.168.89.34
rsync -az \
  /d/Projects/comstar/terminal/admin/components/agents.js \
  /d/Projects/comstar/terminal/admin/admin.css \
  "$HOST:/opt/comstar/src/terminal/admin/"
# agents.js lands in admin/ — put it back under components/
rsync -az /d/Projects/comstar/terminal/admin/components/agents.js \
  "$HOST:/opt/comstar/src/terminal/admin/components/agents.js"
rsync -az /d/Projects/comstar/terminal/admin/admin.css \
  "$HOST:/opt/comstar/src/terminal/admin/admin.css"
ssh "$HOST" 'grep -n "agents-picker\|buildAgentPool\|Enable id" /opt/comstar/src/terminal/admin/components/agents.js | head -8'
echo OK
