#!/usr/bin/env bash
# COMSTAR HDMI output only.
# Uses PipeWire node comstar_hdmi (api.alsa.path=hdmi:0, card 0 = vc4hdmi0).
# ACP HDMI / headphones profiles must stay off — dual-open of vc4-hdmi breaks playback.
set -euo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

for _ in $(seq 1 60); do
  pactl info >/dev/null 2>&1 && break
  sleep 0.5
done

pactl set-card-profile alsa_card.platform-fe00b840.mailbox off 2>/dev/null || true
pactl set-card-profile alsa_card.platform-fef00700.hdmi off 2>/dev/null || true
pactl set-card-profile alsa_card.platform-fef05700.hdmi off 2>/dev/null || true

SINK=""
for _ in $(seq 1 40); do
  if pactl list short sinks | awk '{print $2}' | grep -qx comstar_hdmi; then
    SINK=comstar_hdmi
    break
  fi
  sleep 0.5
done

if [[ -z "$SINK" ]]; then
  echo "ERROR: comstar_hdmi sink missing (check ~/.config/pipewire/pipewire.conf.d/99-comstar-hdmi.conf)"
  pactl list short sinks || true
  exit 1
fi

pactl set-default-sink "$SINK"
pactl set-sink-mute "$SINK" 0 || true
pactl set-sink-volume "$SINK" 100% || true
for id in $(pactl list short sink-inputs | awk '{print $1}'); do
  pactl move-sink-input "$id" "$SINK" 2>/dev/null || true
done

echo "default_sink=$(pactl get-default-sink)"
pactl get-sink-volume @DEFAULT_SINK@ || true

pactl set-source-mute @DEFAULT_SOURCE@ 0 2>/dev/null || true
