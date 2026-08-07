#!/usr/bin/env bash
# Install Road VPN phone-home dependencies on the COMSTAR Pi (ADR 0011).
# Usage:
#   sudo bash scripts/install-road-vpn.sh
#   make road-vpn   # via SSH as root bits on the Pi
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUDOERS_SRC="$ROOT/deploy/sudoers/comstar-road"
SUDOERS_DST="/etc/sudoers.d/comstar-road"
BRIDGE_USER="${COMSTAR_BRIDGE_USER:-md-admin}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

echo "==> Installing NetworkManager VPN plugins"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y \
  network-manager \
  network-manager-openvpn \
  network-manager-l2tp \
  strongswan \
  libstrongswan-standard-plugins \
  xl2tpd

# Ensure NM is running (Pi images sometimes leave it masked during bring-up).
systemctl enable --now NetworkManager.service 2>/dev/null || true

echo "==> Installing sudoers for non-interactive nmcli ($BRIDGE_USER)"
if [[ -f "$SUDOERS_SRC" ]]; then
  # Rewrite user if needed.
  sed "s/^md-admin /$BRIDGE_USER /" "$SUDOERS_SRC" >"$SUDOERS_DST.tmp"
  if ! visudo -cf "$SUDOERS_DST.tmp"; then
    rm -f "$SUDOERS_DST.tmp"
    echo "sudoers validation failed" >&2
    exit 1
  fi
  install -m 440 "$SUDOERS_DST.tmp" "$SUDOERS_DST"
  rm -f "$SUDOERS_DST.tmp"
  echo "installed $SUDOERS_DST"
else
  cat >"$SUDOERS_DST" <<EOF
# COMSTAR road VPN — non-interactive nmcli
$BRIDGE_USER ALL=(root) NOPASSWD: /usr/bin/nmcli
EOF
  chmod 440 "$SUDOERS_DST"
  visudo -cf "$SUDOERS_DST"
fi

echo "==> Verifying"
command -v nmcli >/dev/null
sudo -u "$BRIDGE_USER" -n sudo -n nmcli -t -f NAME connection show >/dev/null \
  || echo "WARN: $BRIDGE_USER cannot sudo -n nmcli yet (log out/in or check sudoers)" >&2

# Plugin presence (best-effort).
nmcli connection show >/dev/null
if ! dpkg -l network-manager-openvpn 2>/dev/null | grep -q '^ii'; then
  echo "WARN: network-manager-openvpn not installed as expected" >&2
fi
if ! dpkg -l network-manager-l2tp 2>/dev/null | grep -q '^ii'; then
  echo "WARN: network-manager-l2tp not installed as expected" >&2
fi

echo "Road VPN packages ready."
echo "Next: open admin → Road VPN → paste credentials → Initialize → enable monitor."
