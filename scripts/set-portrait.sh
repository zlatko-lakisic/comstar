#!/usr/bin/env bash
# Apply portrait orientation for the COMSTAR panel (labwc / wlroots).
# Usage: set-portrait.sh [90|270|normal]
#   90  = rotate output 90° clockwise (default)
#   270 = rotate output 90° counter-clockwise
#   normal = landscape
#
# Panel: 7" IPS 1024×600 @ 60Hz (product native). EDID often lies with
# preferred 1024×768 (4:3), which stretches the avatar into a tall oval when
# the glass is portrait-mounted. Drive native 1024×600 + transform 90 →
# logical 600×1024.
set -euo pipefail

TRANSFORM="${1:-90}"
OUTPUT="${COMSTAR_DISPLAY_OUTPUT:-HDMI-A-1}"
# Override with COMSTAR_DISPLAY_MODE=1024x768 only for debugging EDID preferred.
MODE="${COMSTAR_DISPLAY_MODE:-1024x600}"

export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

if ! command -v wlr-randr >/dev/null 2>&1; then
  echo "wlr-randr not found" >&2
  exit 1
fi

# Wait briefly for the output to appear (boot race).
for _ in $(seq 1 30); do
  if wlr-randr 2>/dev/null | grep -q "^${OUTPUT} "; then
    break
  fi
  sleep 0.5
done

apply_mode() {
  local mode="$1"
  if wlr-randr 2>/dev/null | grep -qE "^[[:space:]]+${mode//\//\\/} px,"; then
    wlr-randr --output "$OUTPUT" --mode "$mode" --transform "$TRANSFORM"
    return 0
  fi
  # Not in EDID — try as custom timing (labwc/wlroots accepts this for 720p).
  if wlr-randr --output "$OUTPUT" --custom-mode "${mode}@60Hz" --transform "$TRANSFORM" 2>/dev/null; then
    return 0
  fi
  return 1
}

if ! apply_mode "$MODE"; then
  echo "Mode ${MODE} failed; falling back to preferred + transform only" >&2
  wlr-randr --output "$OUTPUT" --preferred --transform "$TRANSFORM" || \
    wlr-randr --output "$OUTPUT" --transform "$TRANSFORM"
fi

echo "Applied mode=${MODE} transform=${TRANSFORM} on ${OUTPUT}"
wlr-randr 2>/dev/null | head -20 || true
