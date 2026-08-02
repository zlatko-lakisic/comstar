#!/usr/bin/env bash
# Apply portrait orientation for the COMSTAR panel (labwc / wlroots).
# Usage: set-portrait.sh [90|270|normal]
#   90  = rotate output 90° clockwise (default)
#   270 = rotate output 90° counter-clockwise
#   normal = landscape
set -euo pipefail

TRANSFORM="${1:-90}"
OUTPUT="${COMSTAR_DISPLAY_OUTPUT:-HDMI-A-1}"

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

wlr-randr --output "$OUTPUT" --transform "$TRANSFORM"
echo "Applied transform=${TRANSFORM} on ${OUTPUT}"
wlr-randr 2>/dev/null | head -20 || true
