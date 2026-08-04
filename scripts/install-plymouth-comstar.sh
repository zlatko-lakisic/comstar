#!/usr/bin/env bash
# Install COMSTAR Plymouth theme on the Pi (requires root).
# Suppresses the Raspberry rainbow splash when possible.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/deploy/plymouth/comstar"
DST="/usr/share/plymouth/themes/comstar"
CFG_TXT="/boot/firmware/config.txt"
[[ -f "$CFG_TXT" ]] || CFG_TXT="/boot/config.txt"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

if [[ ! -d "$SRC" ]]; then
  echo "missing theme source $SRC" >&2
  exit 1
fi

command -v plymouth >/dev/null 2>&1 || apt-get install -y plymouth plymouth-themes

python3 "$SRC/generate_assets.py"

mkdir -p "$DST"
cp -a "$SRC/comstar.plymouth" "$SRC/comstar.script" "$DST/"
cp -a "$SRC/background.png" "$SRC/mark.png" "$SRC/spinner-00.png" "$DST/"

if command -v plymouth-set-default-theme >/dev/null 2>&1; then
  plymouth-set-default-theme -R comstar
else
  # Bookworm fallback
  if [[ -f /etc/plymouth/plymouthd.conf ]]; then
    sed -i 's/^Theme=.*/Theme=comstar/' /etc/plymouth/plymouthd.conf || true
  fi
  update-initramfs -u
fi

# Hide firmware rainbow / verbose splash when supported.
if [[ -f "$CFG_TXT" ]]; then
  if ! grep -q '^disable_splash=' "$CFG_TXT"; then
    printf '\n# COMSTAR: hide firmware rainbow under Plymouth\ndisable_splash=1\n' >>"$CFG_TXT"
    echo "appended disable_splash=1 to $CFG_TXT"
  fi
fi

# Ensure quiet splash on cmdline if present.
CMDLINE="/boot/firmware/cmdline.txt"
[[ -f "$CMDLINE" ]] || CMDLINE="/boot/cmdline.txt"
if [[ -f "$CMDLINE" ]]; then
  if ! grep -q 'splash' "$CMDLINE"; then
    # Append splash quiet — keep as single line.
    sed -i 's/$/ quiet splash plymouth.ignore-serial-consoles/' "$CMDLINE"
    echo "updated $CMDLINE with quiet splash"
  fi
fi

echo "COMSTAR Plymouth theme installed. Reboot to see early boot splash."
echo "Preview (on a VT with plymouth): sudo plymouthd; sudo plymouth --show-splash; sleep 5; sudo plymouth --quit"
