#!/usr/bin/env bash
# COMSTAR HDMI output only (vc4-hdmi-0 / HDMI-A-1).
#
# Uses WirePlumber's ACP HDMI sink (renamed to comstar_hdmi via
# wireplumber/51-comstar-hdmi.lua). Do not use module-remap-sink: under
# PipeWire the remap follower often stays unlinked/corked while paplay
# still reports success — silent playback.
#
# Do not load a PipeWire context.objects adapter unless it is known-good:
# a hard-failing adapter takes down all of PipeWire (status 234).
set -euo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

for _ in $(seq 1 60); do
  pactl info >/dev/null 2>&1 && break
  sleep 0.5
done
if ! pactl info >/dev/null 2>&1; then
  echo "ERROR: PipeWire/Pulse not reachable"
  exit 1
fi

# Drop any stale remap alias — it can swallow audio without opening the PCM.
while read -r mid; do
  [[ -n "$mid" ]] || continue
  pactl unload-module "$mid" 2>/dev/null || true
done < <(pactl list modules short 2>/dev/null | awk '/module-remap-sink/ && /comstar_hdmi/{print $1}')

# Headphones / spare HDMI must stay off — dual-open of vc4-hdmi breaks playback.
pactl set-card-profile alsa_card.platform-fe00b840.mailbox off 2>/dev/null || true
pactl set-card-profile alsa_card.platform-fef05700.hdmi off 2>/dev/null || true

# Primary panel HDMI (vc4-hdmi-0). Match by ALSA card name, not PipeWire Name=.
HDMI_CARD=$(pactl list cards | python3 -c '
import sys
for block in sys.stdin.read().split("Card #"):
    if "alsa.card_name = \"vc4-hdmi-0\"" not in block:
        continue
    for line in block.splitlines():
        line = line.strip()
        if line.startswith("Name:"):
            print(line.split(":", 1)[1].strip())
            raise SystemExit
')
if [[ -z "$HDMI_CARD" ]]; then
  HDMI_CARD=alsa_card.platform-fef00700.hdmi
fi

pactl set-card-profile "$HDMI_CARD" output:hdmi-stereo 2>/dev/null \
  || pactl set-card-profile "$HDMI_CARD" output:stereo-fallback 2>/dev/null \
  || true

# Prefer WirePlumber rename (comstar_hdmi); fall back to ACP node name.
SINK=""
for _ in $(seq 1 40); do
  if pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx comstar_hdmi; then
    SINK=comstar_hdmi
    break
  fi
  if pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -q 'platform-fef00700\.hdmi'; then
    SINK=$(pactl list short sinks | awk '/platform-fef00700\.hdmi/{print $2; exit}')
    break
  fi
  # Generic: any HDMI sink that is not hdmi-1.
  SINK=$(pactl list short sinks 2>/dev/null | awk '
    $2 ~ /hdmi/ && $2 !~ /hdmi-1/ && $2 !~ /hdmi1/ {print $2; exit}
  ')
  [[ -n "$SINK" ]] && break
  sleep 0.5
done

if [[ -z "$SINK" ]]; then
  echo "ERROR: no HDMI sink after enabling $HDMI_CARD"
  pactl list short sinks || true
  pactl list cards | grep -E 'Name:|alsa.card_name|Active Profile' || true
  exit 1
fi

pactl set-default-sink "$SINK"
pactl set-sink-mute "$SINK" 0 || true
pactl set-sink-volume "$SINK" 100% || true
for id in $(pactl list short sink-inputs | awk '{print $1}'); do
  pactl move-sink-input "$id" "$SINK" 2>/dev/null || true
done

echo "hdmi_card=$HDMI_CARD default_sink=$(pactl get-default-sink)"
pactl get-sink-volume @DEFAULT_SINK@ || true

# Prefer USB webcam mic; never leave the HDMI monitor as default source.
MIC="$(pactl list short sources 2>/dev/null | awk '$2 !~ /\.monitor$/ && tolower($2) ~ /c525|usb|webcam/ {print $2; exit}')"
if [[ -n "$MIC" ]]; then
  pactl set-default-source "$MIC" 2>/dev/null || true
  pactl set-source-mute "$MIC" 0 2>/dev/null || true
else
  pactl set-source-mute @DEFAULT_SOURCE@ 0 2>/dev/null || true
fi
