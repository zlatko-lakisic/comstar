#!/bin/sh
# COMSTAR Wayland session: labwc WITHOUT --merge-config so /etc/xdg/labwc
# does not start pcmanfm/wf-panel (desktop chrome).
set -eu

# Mirror useful bits from /usr/bin/labwc-pi / setup_env without pulling desktop chrome.
if [ -f /usr/bin/setup_env ]; then
  # shellcheck disable=SC1091
  . /usr/bin/setup_env
fi

export XCURSOR_THEME="${XCURSOR_THEME:-comstar-none}"
export XCURSOR_SIZE="${XCURSOR_SIZE:-24}"
export GTK_THEME="${GTK_THEME:-Adwaita-dark}"
export DESKTOP_SESSION=comstar-labwc

if command -v raspi-config >/dev/null 2>&1; then
  if raspi-config nonint is_pi 2>/dev/null && ! raspi-config nonint gpu_has_mmu 2>/dev/null; then
    export WLR_RENDERER=pixman
  fi
fi

if [ -f "$HOME/.config/gtk-3.0/gtk.css" ]; then
  rm -f "$HOME/.config/gtk-3.0/gtk.css"
  sync
fi

mkdir -p "$HOME/.config/kanshi"
touch "$HOME/.config/kanshi/config"

# No -m / --merge-config: only ~/.config/labwc (our autostart, no Pi desktop chrome).
exec /usr/bin/labwc "$@"
