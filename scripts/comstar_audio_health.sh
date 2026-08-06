#!/usr/bin/env bash
# COMSTAR PipeWire / Pulse audio health + heal.
# Restores the known-good Pi path: comstar_hdmi (ACP HDMI-0 renamed), spare
# HDMI + headphones off, default mic unmuted.
# Called from scripts/comstar_health.sh or standalone:
#   COMSTAR_HEALTH_HEAL=1 bash scripts/comstar_audio_health.sh
set -euo pipefail

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

HEAL="${COMSTAR_HEALTH_HEAL:-0}"
SPEAKER="${COMSTAR_SPEAKER_SOURCE:-comstar_hdmi}"
ROOT="${COMSTAR_ROOT:-/opt/comstar/src}"
PREFER="${COMSTAR_PREFER_HDMI:-$HOME/.config/comstar/prefer-hdmi-audio.sh}"
if [[ ! -x "$PREFER" && -x "$ROOT/deploy/pi-session/prefer-hdmi-audio.sh" ]]; then
  PREFER="$ROOT/deploy/pi-session/prefer-hdmi-audio.sh"
fi
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/comstar-health"
mkdir -p "$STATE_DIR"
LOG_TAG="comstar-audio-health"
COOLDOWN_SEC="${COMSTAR_AUDIO_HEAL_COOLDOWN_SEC:-300}"

PASS=0
FAIL=0
HEALED=0

log() { printf '%s\n' "$*"; logger -t "$LOG_TAG" -- "$*" 2>/dev/null || true; }
ok() { PASS=$((PASS + 1)); log "OK   $*"; }
bad() { FAIL=$((FAIL + 1)); log "FAIL $*"; }
healed() { HEALED=$((HEALED + 1)); log "HEAL $*"; }

unit_active() { systemctl --user is-active --quiet "$1" 2>/dev/null; }

in_cooldown() {
  local f="$STATE_DIR/audio_heal_ts"
  [[ -f "$f" ]] || return 1
  local last now
  last="$(cat "$f" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  [[ "$last" =~ ^[0-9]+$ ]] || return 1
  (( now - last < COOLDOWN_SEC ))
}

mark_healed() {
  date +%s >"$STATE_DIR/audio_heal_ts"
}

bump_miss() {
  local key="$1"
  local need="${2:-2}"
  local f="$STATE_DIR/${key}_miss"
  local miss=0
  [[ -f "$f" ]] && miss="$(cat "$f" 2>/dev/null || echo 0)"
  miss=$((miss + 1))
  echo "$miss" >"$f"
  (( miss >= need ))
}

clear_miss() {
  echo 0 >"$STATE_DIR/${1}_miss"
}

pactl_ok() {
  pactl info >/dev/null 2>&1
}

ensure_pw_stack() {
  systemctl --user reset-failed pipewire.service pipewire-pulse.service wireplumber.service 2>/dev/null || true
  systemctl --user start pipewire.socket pipewire.service 2>/dev/null || true
  systemctl --user start wireplumber.service 2>/dev/null || true
  systemctl --user start pipewire-pulse.socket pipewire-pulse.service 2>/dev/null || true
  sleep 2
}

restart_pw_stack() {
  systemctl --user restart pipewire.service wireplumber.service pipewire-pulse.service 2>/dev/null || true
  sleep 3
  ensure_pw_stack
}

run_prefer_hdmi() {
  if [[ -x "$PREFER" ]]; then
    "$PREFER" >/tmp/comstar-prefer-hdmi.log 2>&1 || return 1
    return 0
  fi
  # Inline minimal restore if prefer script missing (ACP primary ON).
  pactl set-card-profile alsa_card.platform-fe00b840.mailbox off 2>/dev/null || true
  pactl set-card-profile alsa_card.platform-fef05700.hdmi off 2>/dev/null || true
  pactl set-card-profile alsa_card.platform-fef00700.hdmi output:hdmi-stereo 2>/dev/null || true
  if pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx "$SPEAKER"; then
    pactl set-default-sink "$SPEAKER"
    pactl set-sink-mute "$SPEAKER" 0 || true
    pactl set-sink-volume "$SPEAKER" 100% || true
    return 0
  fi
  return 1
}

unmute_mic() {
  pactl set-source-mute @DEFAULT_SOURCE@ 0 2>/dev/null || true
  # Prefer USB webcam mic when present.
  local src
  src="$(pactl list short sources 2>/dev/null | awk '$2 !~ /\.monitor$/ {print $2}' | grep -i 'C525\|usb\|Webcam' | head -1 || true)"
  if [[ -n "$src" ]]; then
    pactl set-default-source "$src" 2>/dev/null || true
    pactl set-source-mute "$src" 0 2>/dev/null || true
  fi
}

heal_audio() {
  local reason="$1"
  [[ "$HEAL" == "1" ]] || return 0
  if in_cooldown; then
    log "SKIP audio heal ($reason) — cooldown ${COOLDOWN_SEC}s"
    return 0
  fi
  log "healing audio: $reason"
  # Never auto-install pipewire.conf.d HDMI adapters — a bad path exits PW 234.
  ensure_pw_stack
  if ! pactl_ok || ! pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx "$SPEAKER"; then
    restart_pw_stack
  fi
  if run_prefer_hdmi; then
    healed "prefer-hdmi ($reason)"
  else
    bad "prefer-hdmi failed after stack restart"
  fi
  unmute_mic
  # Capture client often holds a dead stream after PipeWire restart.
  systemctl --user restart comstar-audio.service 2>/dev/null || true
  sleep 2
  if unit_active comstar-audio; then
    healed "restarted comstar-audio"
  fi
  mark_healed
}

sink_exists() {
  pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx "$1"
}

default_sink() {
  pactl get-default-sink 2>/dev/null || true
}

sink_muted() {
  pactl get-sink-mute "$1" 2>/dev/null | grep -qi 'yes'
}

acp_spare_stolen() {
  # Dual-open breaks HDMI audio — headphones + spare HDMI (hdmi-1) must stay off.
  # Primary vc4-hdmi-0 (fef00700) must stay ON; that is the comstar_hdmi ACP path.
  local name profile
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    profile="$(pactl list cards 2>/dev/null | awk -v n="$name" '
      $1=="Name:" && $2==n {hit=1; next}
      hit && $1=="Active" && $2=="Profile:" {print $3; exit}
    ')"
    if [[ -n "$profile" && "$profile" != "off" ]]; then
      log "     card $name profile=$profile (want off)"
      return 0
    fi
  done < <(pactl list cards short 2>/dev/null | awk '{print $2}' | grep -E 'platform-fef05700\.hdmi|platform-fe00b840\.mailbox' || true)
  return 1
}

primary_hdmi_off() {
  local name profile
  name="$(pactl list cards 2>/dev/null | python3 -c '
import sys
for block in sys.stdin.read().split("Card #"):
    if "alsa.card_name = \"vc4-hdmi-0\"" not in block:
        continue
    for line in block.splitlines():
        line = line.strip()
        if line.startswith("Name:"):
            print(line.split(":", 1)[1].strip())
            raise SystemExit
' 2>/dev/null || true)"
  [[ -n "$name" ]] || name=alsa_card.platform-fef00700.hdmi
  profile="$(pactl list cards 2>/dev/null | awk -v n="$name" '
    $1=="Name:" && $2==n {hit=1; next}
    hit && $1=="Active" && $2=="Profile:" {print $3; exit}
  ')"
  if [[ -z "$profile" || "$profile" == "off" ]]; then
    log "     card $name profile=${profile:-missing} (want hdmi-stereo)"
    return 0
  fi
  return 1
}

default_source() {
  pactl get-default-source 2>/dev/null || true
}

source_muted() {
  pactl get-source-mute @DEFAULT_SOURCE@ 2>/dev/null | grep -qi 'yes'
}

source_is_monitor() {
  local s
  s="$(default_source)"
  [[ "$s" == *.monitor ]]
}

log "COMSTAR audio health $(date -Is) heal=$HEAL speaker=$SPEAKER"

# --- PipeWire stack ---
pw_bad=0
for u in pipewire wireplumber pipewire-pulse; do
  if unit_active "$u"; then
    ok "unit $u"
  else
    bad "unit $u inactive"
    pw_bad=1
  fi
done

if ! pactl_ok; then
  bad "pactl unreachable"
  pw_bad=1
fi

if (( pw_bad )); then
  if bump_miss audio_pw 2; then
    heal_audio "pipewire stack down"
    clear_miss audio_pw
  fi
else
  clear_miss audio_pw
fi

# Re-probe after possible heal.
if pactl_ok; then
  # --- speaker sink ---
  if sink_exists "$SPEAKER"; then
    ok "sink $SPEAKER"
    clear_miss audio_sink
  else
    bad "sink $SPEAKER missing"
    if bump_miss audio_sink 2; then
      heal_audio "missing $SPEAKER"
      clear_miss audio_sink
    fi
  fi

  ds="$(default_sink)"
  if [[ "$ds" == "$SPEAKER" ]]; then
    ok "default sink=$ds"
    clear_miss audio_default_sink
  else
    bad "default sink=$ds (want $SPEAKER)"
    if bump_miss audio_default_sink 2; then
      heal_audio "wrong default sink"
      clear_miss audio_default_sink
    fi
  fi

  if sink_exists "$SPEAKER"; then
    if sink_muted "$SPEAKER"; then
      bad "sink $SPEAKER muted"
      if [[ "$HEAL" == "1" ]]; then
        pactl set-sink-mute "$SPEAKER" 0 || true
        pactl set-sink-volume "$SPEAKER" 100% || true
        healed "unmuted $SPEAKER"
      fi
    else
      ok "sink $SPEAKER unmuted"
    fi
  fi

  if acp_spare_stolen; then
    bad "headphones/spare HDMI profile active (dual-open risk)"
    if bump_miss audio_acp 1; then
      if [[ "$HEAL" == "1" ]]; then
        if run_prefer_hdmi; then
          healed "spare ACP profiles forced off"
        else
          heal_audio "ACP spare steal"
        fi
      fi
      clear_miss audio_acp
    fi
  else
    ok "headphones/spare HDMI off"
    clear_miss audio_acp
  fi

  if primary_hdmi_off; then
    bad "primary HDMI profile off"
    if bump_miss audio_primary_hdmi 1; then
      if [[ "$HEAL" == "1" ]]; then
        if run_prefer_hdmi; then
          healed "primary HDMI profile restored"
        else
          heal_audio "primary HDMI off"
        fi
      fi
      clear_miss audio_primary_hdmi
    fi
  else
    ok "primary HDMI profile on"
    clear_miss audio_primary_hdmi
  fi

  # --- mic / source ---
  src="$(default_source)"
  if [[ -z "$src" || "$src" == "@DEFAULT_SOURCE@" ]]; then
    bad "no default source"
    if bump_miss audio_mic 2; then
      heal_audio "no default mic"
      clear_miss audio_mic
    fi
  elif source_is_monitor; then
    bad "default source is monitor ($src)"
    if bump_miss audio_mic 2; then
      if [[ "$HEAL" == "1" ]]; then
        unmute_mic
        healed "switched off monitor source"
        systemctl --user restart comstar-audio.service 2>/dev/null || true
        mark_healed
      fi
      clear_miss audio_mic
    fi
  else
    ok "default source=$src"
    clear_miss audio_mic
  fi

  if source_muted; then
    bad "default source muted"
    if [[ "$HEAL" == "1" ]]; then
      unmute_mic
      healed "unmuted default source"
    fi
  else
    ok "default source unmuted"
  fi
else
  bad "skip sink/source checks (no pactl)"
fi

log "Audio results: PASS=$PASS FAIL=$FAIL HEALED=$HEALED"
# Non-zero only when not healing and checks failed (caller aggregates).
if [[ "$HEAL" == "1" ]]; then
  exit 0
fi
[[ "$FAIL" -eq 0 ]]
