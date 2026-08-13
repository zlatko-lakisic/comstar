#!/usr/bin/env bash
set -euo pipefail
export HOME=/c/Users/Zlatko.Lakisic
export PATH=/d/Projects/comstar/.tmp/bin:/usr/bin:$PATH
HOST=md-admin@192.168.89.34
rsync -az /d/Projects/comstar/terminal/bridge/lib/attention/coordinator.dart \
  "$HOST:/opt/comstar/src/terminal/bridge/lib/attention/coordinator.dart"
ssh "$HOST" 'systemctl --user restart comstar-bridge; sleep 5; systemctl --user is-active comstar-bridge'
