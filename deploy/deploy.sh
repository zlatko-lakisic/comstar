#!/usr/bin/env bash
# Sync COMSTAR source to the Pi and refresh bridge deps.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE="${COMSTAR_DEPLOY_HOST:-md-admin@192.168.89.34}"
REMOTE_DIR="${COMSTAR_DEPLOY_DIR:-/opt/comstar/src}"
RESTART="${COMSTAR_DEPLOY_RESTART:-1}"

echo "Deploying $ROOT → $REMOTE:$REMOTE_DIR"

rsync -az --delete \
  --exclude '.git/' \
  --exclude 'vendor/agentic-orchestration/' \
  --exclude '.venv/' \
  --exclude '.venv-stt/' \
  --exclude 'node_modules/' \
  --exclude '.dart_tool/' \
  --exclude 'terminal/bridge/build/' \
  "$ROOT/" "$REMOTE:$REMOTE_DIR/"

echo "Running dart pub get on bridge…"
ssh "$REMOTE" "cd '$REMOTE_DIR/terminal/bridge' && dart pub get"

if [[ "$RESTART" == "1" ]]; then
  echo "Restarting user systemd units (if present)…"
  ssh "$REMOTE" bash -s <<'EOF'
set -euo pipefail
units=(comstar-bridge comstar-audio comstar-kiosk)
for unit in "${units[@]}"; do
  if systemctl --user list-unit-files --type=service "$unit.service" 2>/dev/null | grep -q "$unit.service"; then
    systemctl --user restart "$unit.service" && echo "  restarted $unit"
  else
    echo "  skip $unit (not installed)"
  fi
done
EOF
fi

echo "Deploy complete."
