#!/usr/bin/env bash
# Launch Chromium: COMSTAR splash first, then hand off to the live kiosk URL.
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
CHROME="${COMSTAR_CHROMIUM:-}"
if [[ -z "$CHROME" ]]; then
  # Prefer the real binary: /usr/bin/chromium wraps Pi flags (--load-extension,
  # --use-angle=gles, …) that have interfered with kiosk bring-up.
  if [[ -x /usr/lib/chromium/chromium ]]; then
    CHROME=/usr/lib/chromium/chromium
  else
    CHROME=/usr/bin/chromium
  fi
fi
SPLASH_PORT="${COMSTAR_KIOSK_SPLASH_PORT:-8769}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KIOSK_DIR="${COMSTAR_KIOSK_DIR:-$ROOT/terminal/kiosk}"

# Wait for user labwc (not the LightDM greeter).
for _ in $(seq 1 60); do
  if pgrep -u "$(id -u)" -x labwc >/dev/null && pgrep -af 'labwc' | grep -vq greeter; then
    break
  fi
  sleep 0.5
done

# Portrait panel: rotate compositor output before Chromium goes fullscreen.
# Override with COMSTAR_DISPLAY_TRANSFORM=270|normal if the panel is flipped.
PORTRAIT_SCRIPT="$SCRIPT_DIR/set-portrait.sh"
if [[ -x "$PORTRAIT_SCRIPT" ]]; then
  "$PORTRAIT_SCRIPT" "${COMSTAR_DISPLAY_TRANSFORM:-90}" || true
fi

# Local splash HTTP server so Chromium shows branded artwork before bridge :8776 is up.
# Polling the bridge from this origin needs Access-Control-Allow-Origin on kiosk GETs.
ensure_splash_server() {
  local probe="http://127.0.0.1:${SPLASH_PORT}/splash.html"
  if curl -fsS -m 0.4 "$probe" >/dev/null 2>&1; then
    return 0
  fi
  # Drop a stale listener if the port is wedged.
  if command -v fuser >/dev/null 2>&1; then
    fuser -k "${SPLASH_PORT}/tcp" >/dev/null 2>&1 || true
  fi
  python3 -m http.server "$SPLASH_PORT" --bind 127.0.0.1 --directory "$KIOSK_DIR" \
    >/tmp/comstar-kiosk-splash.log 2>&1 &
  disown || true
  for _ in $(seq 1 40); do
    if curl -fsS -m 0.4 "$probe" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  echo "warning: splash server on :${SPLASH_PORT} did not become ready" >&2
  return 1
}

ensure_splash_server || true

# Prefer same-origin kiosk when the bridge is already up. Splash on :8769 fetching
# :8776 is cross-origin; recent Chromium Private Network Access often blocks it,
# leaving the panel on "Waiting for bridge…" forever with no avatar.
if curl -fsS -m 0.6 "http://127.0.0.1:8776/kiosk/boot.txt" >/dev/null 2>&1; then
  START_URL="$URL"
  echo "Kiosk start direct (bridge ready)"
else
  # Encode ? and & inside target so bloom/fps stay on the kiosk URL, not splash.
  TARGET_Q=$(URL="$URL" python3 -c 'import urllib.parse,os; print(urllib.parse.quote(os.environ["URL"], safe=":/"))')
  if curl -fsS -m 0.4 "http://127.0.0.1:${SPLASH_PORT}/splash.html" >/dev/null 2>&1; then
    START_URL="http://127.0.0.1:${SPLASH_PORT}/splash.html?target=${TARGET_Q}"
  elif curl -fsS -m 0.4 "http://127.0.0.1:8776/kiosk/splash.html" >/dev/null 2>&1; then
    START_URL="http://127.0.0.1:8776/kiosk/splash.html?target=${TARGET_Q}"
  else
    # Last resort: open kiosk URL directly (may blank until bridge is up).
    START_URL="$URL"
  fi
fi

mkdir -p "$PROFILE"
# Drop stale Chromium locks / orphaned renderers from a previous crash so we
# don't get a blank kiosk window fighting for the Wayland seat.
rm -f "$PROFILE/SingletonLock" "$PROFILE/SingletonCookie" "$PROFILE/SingletonSocket" 2>/dev/null || true
if command -v pkill >/dev/null 2>&1; then
  pkill -f -- "--user-data-dir=${PROFILE}" >/dev/null 2>&1 || true
  sleep 0.3
fi

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
echo "Kiosk start ${START_URL%%\?*}"

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
  "$START_URL"
