#!/usr/bin/env bash
# Install blank COMSTAR session (no desktop chrome flash).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/deploy/pi-session"
LABWC_DST="${XDG_CONFIG_HOME:-$HOME/.config}/labwc"
SESSIONS_DST="${XDG_DATA_HOME:-$HOME/.local/share}/wayland-sessions"
LIGHTDM_SNIPPET="$SRC/lightdm/50-comstar.conf"
LIGHTDM_DST="/etc/lightdm/lightdm.conf.d/50-comstar.conf"
SYSTEM_SESSION_DST="/usr/share/wayland-sessions/comstar-labwc.desktop"

backup_once() {
  local f="$1"
  if [[ -f "$f" && ! -f "${f}.pre-comstar" ]]; then
    cp -a "$f" "${f}.pre-comstar"
    echo "backed up $f → ${f}.pre-comstar"
  fi
}

install_root_bits() {
  mkdir -p /etc/lightdm/lightdm.conf.d
  cp "$LIGHTDM_SNIPPET" "$LIGHTDM_DST"
  echo "installed $LIGHTDM_DST"

  # Raspberry Pi OS LightDM often ignores conf.d for seat keys already set in
  # lightdm.conf — patch the main file (backup once).
  if [[ -f /etc/lightdm/lightdm.conf ]]; then
    if [[ ! -f /etc/lightdm/lightdm.conf.pre-comstar ]]; then
      cp -a /etc/lightdm/lightdm.conf /etc/lightdm/lightdm.conf.pre-comstar
      echo "backed up /etc/lightdm/lightdm.conf"
    fi
    sed -i \
      -e 's/^user-session=.*/user-session=comstar-labwc/' \
      -e 's/^autologin-session=.*/autologin-session=comstar-labwc/' \
      /etc/lightdm/lightdm.conf
    echo "patched /etc/lightdm/lightdm.conf → comstar-labwc"
  fi

  sed "s|^Exec=.*|Exec=$SRC/comstar-session.sh|" \
    "$SRC/comstar-labwc.desktop" >"$SYSTEM_SESSION_DST"
  chmod 644 "$SYSTEM_SESSION_DST"
  echo "installed $SYSTEM_SESSION_DST"

  if ! command -v swaybg >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y swaybg
  fi
  echo "swaybg ready: $(command -v swaybg)"
}

if [[ "${1:-}" == "--root-only" ]]; then
  install_root_bits
  exit 0
fi

mkdir -p "$LABWC_DST" "$SESSIONS_DST"

for name in autostart environment; do
  src="$SRC/labwc/$name"
  dst="$LABWC_DST/$name"
  backup_once "$dst"
  cp "$src" "$dst"
  echo "installed $dst"
done
chmod +x "$LABWC_DST/autostart"

if [[ "${COMSTAR_REPLACE_LABWC_RC:-0}" == "1" ]]; then
  backup_once "$LABWC_DST/rc.xml"
  cp "$SRC/labwc/rc.xml" "$LABWC_DST/rc.xml"
  echo "installed $LABWC_DST/rc.xml"
fi

chmod +x "$SRC/comstar-session.sh"
cp "$SRC/comstar-labwc.desktop" "$SESSIONS_DST/comstar-labwc.desktop"
sed -i "s|^Exec=.*|Exec=$SRC/comstar-session.sh|" "$SESSIONS_DST/comstar-labwc.desktop"
echo "installed $SESSIONS_DST/comstar-labwc.desktop"

rm -f "$HOME/.config/autostart/comstar-no-desktop.desktop"

# HDMI prefer script (PipeWire sink selection after session start).
mkdir -p "$HOME/.config/comstar"
cp "$SRC/prefer-hdmi-audio.sh" "$HOME/.config/comstar/prefer-hdmi-audio.sh"
chmod +x "$HOME/.config/comstar/prefer-hdmi-audio.sh"
echo "installed $HOME/.config/comstar/prefer-hdmi-audio.sh"

# Optional named HDMI sink — install only if missing (machine-specific; do not clobber).
PW_DST="$HOME/.config/pipewire/pipewire.conf.d"
PW_CONF="$PW_DST/99-comstar-hdmi.conf"
if [[ ! -f "$PW_CONF" && ! -f "${PW_CONF}.broken" && ! -f "${PW_CONF}.off" ]]; then
  mkdir -p "$PW_DST"
  cp "$SRC/pipewire/99-comstar-hdmi.conf.example" "$PW_CONF"
  echo "installed $PW_CONF (verify aplay -D hdmi:0 before reboot)"
else
  echo "skip pipewire HDMI conf (already present or previously disabled)"
fi

if [[ "$(id -u)" -eq 0 ]]; then
  install_root_bits
elif [[ "${COMSTAR_INSTALL_LIGHTDM:-1}" == "1" ]]; then
  sudo -n "$0" --root-only || {
    echo "Root bits need an interactive sudo. Run:"
    echo "  sudo $0 --root-only"
    exit 1
  }
fi

echo
echo "COMSTAR session install done."
echo "Reboot (or: sudo systemctl restart lightdm) to enter comstar-labwc."
echo "Restore Pi desktop:"
echo "  sudo cp /etc/lightdm/lightdm.conf.pre-comstar /etc/lightdm/lightdm.conf"
echo "  sudo systemctl restart lightdm"
