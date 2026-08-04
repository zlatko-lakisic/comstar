#!/usr/bin/env bash
# Install blank COMSTAR session chrome (labwc autostart + LightDM hints).
# Idempotent: backs up existing files once with a .pre-comstar suffix.
#
# By default does NOT replace ~/.config/labwc/rc.xml (Pi OS schemas vary).
# Set COMSTAR_REPLACE_LABWC_RC=1 to install the minimal shipped rc.xml.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/deploy/pi-session"
LABWC_DST="${XDG_CONFIG_HOME:-$HOME/.config}/labwc"
LIGHTDM_SNIPPET="$SRC/lightdm/50-comstar.conf"
LIGHTDM_DST="/etc/lightdm/lightdm.conf.d/50-comstar.conf"

backup_once() {
  local f="$1"
  if [[ -f "$f" && ! -f "${f}.pre-comstar" ]]; then
    cp -a "$f" "${f}.pre-comstar"
    echo "backed up $f → ${f}.pre-comstar"
  fi
}

mkdir -p "$LABWC_DST"

install_file() {
  local name="$1"
  local src="$SRC/labwc/$name"
  local dst="$LABWC_DST/$name"
  if [[ ! -f "$src" ]]; then
    echo "missing $src" >&2
    exit 1
  fi
  backup_once "$dst"
  cp "$src" "$dst"
  echo "installed $dst"
}

install_file autostart
install_file environment
chmod +x "$LABWC_DST/autostart" 2>/dev/null || true

if [[ "${COMSTAR_REPLACE_LABWC_RC:-0}" == "1" ]]; then
  install_file rc.xml
else
  echo "skipped labwc/rc.xml (set COMSTAR_REPLACE_LABWC_RC=1 to install minimal rc)"
fi

# Kill desktop panel / file-manager desktop on login; set dark wallpaper if swaybg exists.
mkdir -p "$HOME/.config/autostart"
cat >"$HOME/.config/autostart/comstar-no-desktop.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=COMSTAR hide desktop
Exec=sh -c 'killall pcmanfm 2>/dev/null || true; killall wf-panel-pi 2>/dev/null || true; killall wf-panel 2>/dev/null || true; killall lxpanel 2>/dev/null || true; command -v swaybg >/dev/null && swaybg -c "#06080B" >/dev/null 2>&1 &'
X-GNOME-Autostart-enabled=true
EOF
echo "installed ~/.config/autostart/comstar-no-desktop.desktop"

if [[ "${COMSTAR_INSTALL_LIGHTDM:-1}" == "1" ]]; then
  if [[ -f "$LIGHTDM_SNIPPET" ]]; then
    if [[ "$(id -u)" -eq 0 ]]; then
      mkdir -p /etc/lightdm/lightdm.conf.d
      cp "$LIGHTDM_SNIPPET" "$LIGHTDM_DST"
      echo "installed $LIGHTDM_DST"
    else
      echo "LightDM snippet needs root. Run:"
      echo "  sudo mkdir -p /etc/lightdm/lightdm.conf.d"
      echo "  sudo install -m 644 '$LIGHTDM_SNIPPET' '$LIGHTDM_DST'"
    fi
  fi
fi

echo
echo "COMSTAR session install done."
echo "Re-login or reboot for changes. Temporary desktop restore:"
echo "  systemctl --user stop comstar-kiosk"
echo "  rm -f ~/.config/autostart/comstar-no-desktop.desktop"
echo "  # restore labwc backups (*.pre-comstar) if needed, then re-login"
