#!/usr/bin/env bash
# COMSTAR health check + optional auto-heal for stuck Pi runtime.
# Install as user systemd timer (comstar-health.timer) or run manually:
#   COMSTAR_HEALTH_HEAL=1 bash scripts/comstar_health.sh
set -euo pipefail

HEAL="${COMSTAR_HEALTH_HEAL:-0}"
AO_URL="${COMSTAR_AO_URL:-http://10.0.10.16:8765}"
CPAI_URL="${COMSTAR_CPAI_URL:-http://10.0.10.16:32168}"
BRIDGE_HEALTH="${COMSTAR_BRIDGE_HEALTH:-http://127.0.0.1:8781/admin/health}"
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/comstar-health"
mkdir -p "$STATE_DIR"
LOG_TAG="comstar-health"

PASS=0
FAIL=0
HEALED=0

log() { printf '%s\n' "$*"; logger -t "$LOG_TAG" -- "$*" 2>/dev/null || true; }
ok() { PASS=$((PASS + 1)); log "OK   $*"; }
bad() { FAIL=$((FAIL + 1)); log "FAIL $*"; }
healed() { HEALED=$((HEALED + 1)); log "HEAL $*"; }

port_up() {
  local port="$1"
  ss -ltn 2>/dev/null | grep -qE ":${port} " || \
    ss -ltn 2>/dev/null | grep -qE "127\\.0\\.0\\.1:${port}\\b"
}

http_ok() {
  local url="$1"
  curl -fsS --connect-timeout 2 --max-time 5 "$url" >/dev/null 2>&1
}

unit_active() {
  systemctl --user is-active --quiet "$1"
}

restart_unit() {
  local unit="$1"
  [[ "$HEAL" == "1" ]] || return 0
  # Avoid thrashing while bridge is still booting / opening AO session.
  if [[ "$unit" == "comstar-bridge.service" || "$unit" == "comstar-bridge" ]]; then
    local active_enter
    active_enter="$(systemctl --user show comstar-bridge.service -p ActiveEnterTimestampMonotonic --value 2>/dev/null || echo 0)"
    local now
    now="$(python3 -c 'import time; print(int(time.clock_gettime(time.CLOCK_MONOTONIC)*1e6))' 2>/dev/null || echo 0)"
    if [[ "$active_enter" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ && "$active_enter" -gt 0 ]]; then
      local age_us=$((now - active_enter))
      if (( age_us < 90000000 )); then
        log "SKIP restart $unit (bridge age <90s)"
        return 0
      fi
    fi
  fi
  systemctl --user restart "$unit" || true
  sleep 2
  if unit_active "$unit"; then
    healed "restarted $unit"
  else
    bad "restart $unit still inactive"
  fi
}

inject() {
  local payload="$1"
  [[ "$HEAL" == "1" ]] || return 0
  curl -fsS --connect-timeout 2 --max-time 4 \
    -X POST http://127.0.0.1:8781/admin/inject \
    -H 'Content-Type: application/json' \
    -d "$payload" >/dev/null 2>&1 || return 1
  return 0
}

log "COMSTAR health $(date -Is) heal=$HEAL"

# --- systemd units ---
for u in comstar-bridge comstar-audio comstar-kiosk; do
  if unit_active "$u"; then
    ok "unit $u"
  else
    bad "unit $u inactive"
    restart_unit "$u"
  fi
done

# --- local ports ---
for p in 8777 8778 8776; do
  if port_up "$p"; then
    ok "port $p"
  else
    bad "port $p not listening"
    restart_unit comstar-bridge
  fi
done

# --- AO / CPAI ---
if http_ok "$AO_URL/health"; then
  ok "AO $AO_URL/health"
else
  bad "AO unreachable ($AO_URL/health)"
fi

if http_ok "$CPAI_URL/v1/server/status/ping" || \
   curl -fsS --connect-timeout 2 --max-time 5 -X POST "$CPAI_URL/v1/vision/face/list" >/dev/null 2>&1; then
  ok "CPAI $CPAI_URL"
else
  bad "CPAI unreachable ($CPAI_URL)"
fi

# --- bridge attention health (dev inject /health) ---
HEALTH_JSON=""
if HEALTH_JSON="$(curl -fsS --connect-timeout 2 --max-time 4 "$BRIDGE_HEALTH" 2>/dev/null)"; then
  ok "bridge /health"
  eval "$(HEALTH_JSON="$HEALTH_JSON" python3 - <<'PY'
import json, os, shlex
d = json.loads(os.environ["HEALTH_JSON"])
def emit(name, key, default=""):
    v = d.get(key, default)
    if isinstance(v, bool):
        v = "true" if v else "false"
    print(f"{name}={shlex.quote(str(v))}")
emit("STATE", "state")
emit("KIOSK", "kiosk_connected")
emit("AUDIO", "audio_connected")
emit("REACH", "reach_active")
emit("FLAG", "session_flag")
PY
)"
  log "     state=$STATE reach=$REACH session_flag=$FLAG kiosk=$KIOSK audio=$AUDIO"

  if [[ "$KIOSK" != "true" ]]; then
    bad "kiosk WS disconnected"
    # Count consecutive misses before restarting kiosk
    miss_file="$STATE_DIR/kiosk_miss"
    miss=0
    [[ -f "$miss_file" ]] && miss="$(cat "$miss_file" 2>/dev/null || echo 0)"
    miss=$((miss + 1))
    echo "$miss" >"$miss_file"
    if (( miss >= 2 )); then
      restart_unit comstar-kiosk
      echo 0 >"$miss_file"
    fi
  else
    echo 0 >"$STATE_DIR/kiosk_miss"
  fi

  if [[ "$AUDIO" != "true" ]]; then
    bad "audio WS disconnected"
    miss_file="$STATE_DIR/audio_miss"
    miss=0
    [[ -f "$miss_file" ]] && miss="$(cat "$miss_file" 2>/dev/null || echo 0)"
    miss=$((miss + 1))
    echo "$miss" >"$miss_file"
    if (( miss >= 2 )); then
      restart_unit comstar-audio
      echo 0 >"$miss_file"
    fi
  else
    echo 0 >"$STATE_DIR/audio_miss"
  fi

  # Stuck: attention expects an AO session but Reach is dead (not mid-open).
  if [[ "$STATE" == "engaged" || "$STATE" == "listening" || "$STATE" == "responding" ]]; then
    if [[ "$FLAG" == "true" && "$REACH" != "true" ]]; then
      bad "attention=$STATE session_flag but Reach inactive"
      miss_file="$STATE_DIR/session_miss"
      miss=0
      [[ -f "$miss_file" ]] && miss="$(cat "$miss_file" 2>/dev/null || echo 0)"
      miss=$((miss + 1))
      echo "$miss" >"$miss_file"
      # 3 misses × 2min timer ≈ 6 minutes before restart (avoids AO overlay bootstrap race).
      if (( miss >= 3 )); then
        restart_unit comstar-bridge
        echo 0 >"$miss_file"
      fi
    else
      echo 0 >"$STATE_DIR/session_miss"
    fi
  fi
else
  bad "bridge /health unreachable (inject down?)"
  if unit_active comstar-bridge; then
    # Port 8781 admin/health — still try restart if other ports ok
    if ! port_up 8778; then
      restart_unit comstar-bridge
    fi
  fi
fi

log "Results: PASS=$PASS FAIL=$FAIL HEALED=$HEALED"
# Timer mode: exit 0 unless units still down after heal attempts.
if [[ "$HEAL" == "1" ]]; then
  for u in comstar-bridge comstar-audio comstar-kiosk; do
    unit_active "$u" || exit 1
  done
  exit 0
fi
[[ "$FAIL" -eq 0 ]]
