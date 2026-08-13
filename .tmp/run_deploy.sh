#!/usr/bin/env bash
set -euo pipefail
export HOME=/c/Users/Zlatko.Lakisic
export MSYS2_ARG_CONV_EXCL='*'
export PATH=/d/Projects/comstar/.tmp/bin:/usr/bin:$PATH
export COMSTAR_DEPLOY_HOST=md-admin@192.168.89.34
export COMSTAR_DEPLOY_DIR=/opt/comstar/src
export COMSTAR_DEPLOY_RESTART=1
cd /d/Projects/comstar
echo HOME=$HOME
echo ssh=$(command -v ssh)
ssh -V
ssh "$COMSTAR_DEPLOY_HOST" 'echo SSH_OK'
bash deploy/deploy.sh
ssh "$COMSTAR_DEPLOY_HOST" "find '$COMSTAR_DEPLOY_DIR' -type f -name '*.sh' -exec sed -i 's/\r$//' {} +; systemctl --user --no-pager is-active comstar-bridge comstar-audio comstar-kiosk comstar-stt || true"
echo Deploy finished.
