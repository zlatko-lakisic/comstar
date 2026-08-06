#!/usr/bin/env bash
# COMSTAR HDMI output only (vc4-hdmi-0).
#
# Prefer WirePlumber's ALSA HDMI sink over a PipeWire context.objects adapter:
# a hard-failing adapter (wrong hdmi:N index after card renumber) takes down
# all of PipeWire with status 234.
#
# Creates/uses a remap sink named comstar_hdmi so COMSTAR_SPEAKER_SOURCE stays
# stable across ACP sink name changes.
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
  # Fallback known name on this Pi revision.
  HDMI_CARD=alsa_card.platform-fef00700.hdmi
fi

pactl set-card-profile "$HDMI_CARD" output:hdmi-stereo 2>/dev/null \
  || pactl set-card-profile "$HDMI_CARD" output:stereo-fallback 2>/dev/null \
  || true

MASTER=""
for _ in $(seq 1 40); do
  MASTER=$(pactl list short sinks | awk '
    $2 ~ /hdmi/ && $2 !~ /hdmi-1/ && $2 !~ /hdmi1/ {print $2; exit}
  ')
  # Prefer the vc4-hdmi-0 sink explicitly when present.
  if pactl list short sinks | awk '{print $2}' | grep -q 'platform-fef00700.hdmi'; then
    MASTER=$(pactl list short sinks | awk '/platform-fef00700\.hdmi/{print $2; exit}')
  fi
  [[ -n "$MASTER" ]] && break
  sleep 0.5
done

if [[ -z "$MASTER" ]]; then
  echo "ERROR: no HDMI sink after enabling $HDMI_CARD"
  pactl list short sinks || true
  pactl list cards | grep -E 'Name:|alsa.card_name|Active Profile' || true
  exit 1
fi

# Stable alias for COMSTAR_SPEAKER_SOURCE=comstar_hdmi
if ! pactl list short sinks | awk '{print $2}' | grep -qx comstar_hdmi; then
  # Drop stale remap modules that might reference a dead master.
  while read -r mid; do
    [[ -n "$mid" ]] || continue
    pactl unload-module "$mid" 2>/dev/null || true
  done < <(pactl list modules short 2>/dev/null | awk '/module-remap-sink/ && /comstar_hdmi/{print $1}')
  pactl load-module module-remap-sink sink_name=comstar_hdmi master="$MASTER" remix=no >/dev/null \
    || pactl load-module module-remap-sink sink_name=comstar_hdmi master="$MASTER" >/dev/null
fi

SINK=comstar_hdmi
if ! pactl list short sinks | awk '{print $2}' | grep -qx comstar_hdmi; then
  SINK=$MASTER
fi

pactl set-default-sink "$SINK"
pactl set-sink-mute "$SINK" 0 || true
pactl set-sink-volume "$SINK" 100% || true
for id in $(pactl list short sink-inputs | awk '{print $1}'); do
  pactl move-sink-input "$id" "$SINK" 2>/dev/null || true
done

echo "hdmi_card=$HDMI_CARD master=$MASTER default_sink=$(pactl get-default-sink)"
pactl get-sink-volume @DEFAULT_SINK@ || true

pactl set-source-mute @DEFAULT_SOURCE@ 0 2>/dev/null || true
