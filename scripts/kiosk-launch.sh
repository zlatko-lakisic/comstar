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

# Modest bloom for presence; fps still capped for VideoCore (override via COMSTAR_KIOSK_URL).
URL="${COMSTAR_KIOSK_URL:-http://127.0.0.1:8776/kiosk/?bloom=3&fps=12}"
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
# Portrait panel after transform 90: logical viewport is mode height × width.
# Chromium/Ozone often restores a landscape window into the portrait work area;
# the compositor then stretches that buffer and the avatar becomes a tall ellipse.
COMSTAR_KIOSK_W="${COMSTAR_KIOSK_W:-}"
COMSTAR_KIOSK_H="${COMSTAR_KIOSK_H:-}"
if [[ -z "$COMSTAR_KIOSK_W" || -z "$COMSTAR_KIOSK_H" ]]; then
  # Parse current mode + transform from wlr-randr (default HDMI-A-1).
  read -r COMSTAR_KIOSK_W COMSTAR_KIOSK_H < <(
    python3 - <<'PY'
import os, re, subprocess
out = os.environ.get("COMSTAR_DISPLAY_OUTPUT", "HDMI-A-1")
try:
    text = subprocess.check_output(["wlr-randr"], text=True, stderr=subprocess.DEVNULL)
except Exception:
    print("768 1024")
    raise SystemExit
block, cur = [], False
for line in text.splitlines():
    if re.match(r"^\S", line):
        cur = line.startswith(out + " ") or line.startswith(out + "\t")
    if cur:
        block.append(line)
blob = "\n".join(block)
m = re.search(r"(\d+)x(\d+) px,[\d. ]+Hz \(preferred, current\)", blob) or re.search(
    r"(\d+)x(\d+) px,[\d. ]+Hz \(current\)", blob
)
transform = "normal"
tm = re.search(r"Transform:\s+(\S+)", blob)
if tm:
    transform = tm.group(1)
if not m:
    print("768 1024")
    raise SystemExit
mw, mh = int(m.group(1)), int(m.group(2))
# 90/270 swap axes into logical portrait (or landscape if already swapped).
if transform in ("90", "270", "flipped-90", "flipped-270"):
    print(f"{mh} {mw}")
else:
    print(f"{mw} {mh}")
PY
  )
fi
echo "Kiosk window target ${COMSTAR_KIOSK_W}x${COMSTAR_KIOSK_H}"

# Avoid crash-restore interstitial / blank session restore; pin window to panel.
if [[ -f "$PROFILE/Default/Preferences" ]]; then
  python3 - <<PY
import json
from pathlib import Path
w, h = int("$COMSTAR_KIOSK_W"), int("$COMSTAR_KIOSK_H")
p = Path("$PROFILE") / "Default" / "Preferences"
try:
    d = json.loads(p.read_text())
    d.setdefault("profile", {})["exit_type"] = "Normal"
    d.setdefault("browser", {})["window_placement"] = {
        "bottom": h,
        "left": 0,
        "maximized": True,
        "right": w,
        "top": 0,
        "work_area_bottom": h,
        "work_area_left": 0,
        "work_area_right": w,
        "work_area_top": 0,
    }
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
  --window-size="${COMSTAR_KIOSK_W},${COMSTAR_KIOSK_H}" \
  --window-position=0,0 \
  --kiosk \
  --start-maximized \
  "$URL"
