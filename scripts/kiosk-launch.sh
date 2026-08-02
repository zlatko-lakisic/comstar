#!/usr/bin/env bash
# Launch Chromium kiosk against the bridge static server.
set -euo pipefail

export DISPLAY="${DISPLAY:-:0}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

URL="${COMSTAR_KIOSK_URL:-http://127.0.0.1:8776/kiosk/}"
PROFILE="${COMSTAR_KIOSK_PROFILE:-$HOME/.config/comstar-kiosk-chromium}"
CHROME="${COMSTAR_CHROMIUM:-/usr/bin/chromium}"

for _ in $(seq 1 40); do
  if curl -fsS -m 1 "$URL" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

exec "$CHROME" \
  --ozone-platform=wayland \
  --user-data-dir="$PROFILE" \
  --autoplay-policy=no-user-gesture-required \
  --disable-features=TranslateUI \
  --kiosk \
  --noerrdialogs \
  --disable-session-crashed-bubble \
  --no-first-run \
  --check-for-update-interval=31536000 \
  "$URL"
