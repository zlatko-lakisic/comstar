#!/usr/bin/env bash
set -euo pipefail
export HOME=/c/Users/Zlatko.Lakisic
export PATH=/d/Projects/comstar/.tmp/bin:/usr/bin:$PATH
HOST=md-admin@192.168.89.34
ssh "$HOST" 'rm -f /opt/comstar/src/terminal/admin/agents.js; ls -la /opt/comstar/src/terminal/admin/components/agents.js /opt/comstar/src/terminal/admin/admin.css; grep -c agents-picker /opt/comstar/src/terminal/admin/admin.css'
