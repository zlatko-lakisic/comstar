#!/usr/bin/env bash
# Sync COMSTAR source to the Pi, ensure config, refresh deps, install units.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE="${COMSTAR_DEPLOY_HOST:-comstar}"
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
  --exclude 'terminal/audio/.venv/' \
  --exclude 'config/comstar.yaml' \
  --exclude 'config/comstar.dev.yaml' \
  "$ROOT/" "$REMOTE:$REMOTE_DIR/"

echo "Ensuring production config + systemd units…"
ssh "$REMOTE" "REMOTE_DIR='$REMOTE_DIR' bash -s" <<'EOF'
set -euo pipefail
CFG="$REMOTE_DIR/config/comstar.yaml"
if [[ ! -f "$CFG" ]]; then
  sed "s|overlay_root: ./overlays/comstar|overlay_root: $REMOTE_DIR/overlays/comstar|" \
    "$REMOTE_DIR/config/comstar.example.yaml" > "$CFG"
  echo "created $CFG"
else
  echo "config present: $CFG"
fi

UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"
for unit in comstar-bridge comstar-audio comstar-kiosk comstar-stt comstar-health; do
  src="$REMOTE_DIR/deploy/systemd/${unit}.service"
  if [[ -f "$src" ]]; then
    cp "$src" "$UNIT_DIR/${unit}.service"
    echo "installed $unit.service"
  fi
done
if [[ -f "$REMOTE_DIR/deploy/systemd/comstar-health.timer" ]]; then
  cp "$REMOTE_DIR/deploy/systemd/comstar-health.timer" "$UNIT_DIR/comstar-health.timer"
  echo "installed comstar-health.timer"
fi
chmod +x "$REMOTE_DIR/scripts/comstar_health.sh" 2>/dev/null || true
chmod +x "$REMOTE_DIR/scripts/comstar_audio_health.sh" 2>/dev/null || true
# Autologin fails closed if this loses +x (LightDM falls back to greeter).
chmod +x "$REMOTE_DIR/deploy/pi-session/comstar-session.sh" 2>/dev/null || true
chmod +x "$REMOTE_DIR/scripts/kiosk-launch.sh" 2>/dev/null || true
chmod +x "$REMOTE_DIR/deploy/pi-session/prefer-hdmi-audio.sh" 2>/dev/null || true
# Keep user-session HDMI helpers in sync with the tree.
mkdir -p "$HOME/.config/comstar" "$HOME/.config/wireplumber/main.lua.d"
cp "$REMOTE_DIR/deploy/pi-session/prefer-hdmi-audio.sh" "$HOME/.config/comstar/prefer-hdmi-audio.sh"
chmod +x "$HOME/.config/comstar/prefer-hdmi-audio.sh"
cp "$REMOTE_DIR/deploy/pi-session/wireplumber/51-comstar-hdmi.lua" \
  "$HOME/.config/wireplumber/main.lua.d/51-comstar-hdmi.lua"
systemctl --user daemon-reload
systemctl --user enable comstar-bridge.service comstar-audio.service comstar-kiosk.service comstar-stt.service >/dev/null
systemctl --user enable --now comstar-health.timer >/dev/null 2>&1 || true
EOF

echo "Running dart pub get on bridge…"
ssh "$REMOTE" "cd '$REMOTE_DIR/terminal/bridge' && dart pub get"

if [[ "$RESTART" == "1" ]]; then
  echo "Restarting user systemd units…"
  ssh "$REMOTE" bash -s <<'EOF'
set -euo pipefail
systemctl --user restart comstar-stt.service || true
systemctl --user restart comstar-bridge.service
# Wait until bridge WS port is up (dart compile can take a few seconds)
for i in $(seq 1 30); do
  if ss -ltn | grep -q ':8778 '; then
    echo "bridge listening on 8778"
    break
  fi
  sleep 1
done
systemctl --user restart comstar-audio.service
systemctl --user restart comstar-kiosk.service
sleep 2
systemctl --user --no-pager is-active comstar-bridge comstar-audio comstar-kiosk comstar-stt || true
systemctl --user --no-pager is-active comstar-health.timer 2>/dev/null || true
EOF
fi

echo "Deploy complete."
