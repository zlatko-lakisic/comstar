#!/usr/bin/env bash
# Launch Chromium kiosk against the bridge static server.
set -euo pipefail

export DISPLAY="${DISPLAY:-:0}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
export XDG_SESSION_TYPE="${XDG_SESSION_TYPE:-wayland}"
# Invisible cursor for kiosk (theme installed on device; CSS also sets cursor:none).
export XCURSOR_THEME="${XCURSOR_THEME:-comstar-none}"
export XCURSOR_SIZE="${XCURSOR_SIZE:-24}"

# Default query keeps the SVG avatar cheap on VideoCore (override via COMSTAR_KIOSK_URL).
URL="${COMSTAR_KIOSK_URL:-http://127.0.0.1:8776/kiosk/?bloom=0&fps=12}"
PROFILE="${COMSTAR_KIOSK_PROFILE:-$HOME/.config/comstar-kiosk-chromium}"
CHROME="${COMSTAR_CHROMIUM:-/usr/bin/chromium}"

# Wait for user labwc (not the LightDM greeter).
for _ in $(seq 1 60); do
  if pgrep -u "$(id -u)" -x labwc >/dev/null && pgrep -af 'labwc' | grep -vq greeter; then
    break
  fi
  sleep 0.5
done

for _ in $(seq 1 40); do
  if curl -fsS -m 1 "$URL" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

# Portrait panel: rotate compositor output before Chromium goes fullscreen.
# Override with COMSTAR_DISPLAY_TRANSFORM=270|normal if the panel is flipped.
PORTRAIT_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/set-portrait.sh"
if [[ -x "$PORTRAIT_SCRIPT" ]]; then
  "$PORTRAIT_SCRIPT" "${COMSTAR_DISPLAY_TRANSFORM:-90}" || true
fi

mkdir -p "$PROFILE"
# Avoid crash-restore interstitial / blank session restore.
if [[ -f "$PROFILE/Default/Preferences" ]]; then
  python3 - <<PY
import json
from pathlib import Path
p = Path("$PROFILE") / "Default" / "Preferences"
try:
    d = json.loads(p.read_text())
    d.setdefault("profile", {})["exit_type"] = "Normal"
    p.write_text(json.dumps(d))
except Exception:
    pass
PY
fi

exec "$CHROME" \
  --ozone-platform=wayland \
  --enable-features=UseOzonePlatform \
  --user-data-dir="$PROFILE" \
  --password-store=basic \
  --autoplay-policy=no-user-gesture-required \
  --disable-features=TranslateUI \
  --disable-extensions \
  --disable-component-extensions-with-background-pages \
  --disable-session-crashed-bubble \
  --hide-crash-restore-bubble \
  --noerrdialogs \
  --no-first-run \
  --check-for-update-interval=31536000 \
  --disable-background-networking \
  --disable-sync \
  --disable-default-apps \
  --no-pings \
  --metrics-recording-only \
  --num-raster-threads=1 \
  --renderer-process-limit=2 \
  --kiosk \
  --start-maximized \
  "$URL"
