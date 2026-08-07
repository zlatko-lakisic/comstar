#!/usr/bin/env bash
# Live driveway visitor history via bridge inject → vision MCP (not AO/qwen).
# Requires COMSTAR_ENV=dev (admin inject) and COMSTAR_VISION_MCP_URL on the bridge.
#
#   ssh comstar 'bash /opt/comstar/src/scripts/vision_visit_e2e.sh'
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
[[ -f "$HOME/.config/comstar/admin.env" ]] && set -a && source "$HOME/.config/comstar/admin.env" && set +a

ADMIN_TOKEN="${COMSTAR_ADMIN_TOKEN:-${COMSTAR_LAN_TOKEN:-}}"
INJECT_BASE="${INJECT_URL:-http://127.0.0.1:8781/admin/inject}"
if [[ -n "$ADMIN_TOKEN" && "$INJECT_BASE" != *token=* ]]; then
  INJECT="${INJECT_BASE}?token=${ADMIN_TOKEN}"
else
  INJECT="$INJECT_BASE"
fi
USERID="${COMSTAR_USER:-zlatko}"
PASS=0
FAIL=0

log() { printf '%s\n' "$*"; }
ok() { PASS=$((PASS + 1)); log "PASS  $*"; }
bad() { FAIL=$((FAIL + 1)); log "FAIL  $*"; }

now_epoch() { date +%s; }

inject_json() {
  local code
  code="$(curl -sS -o /tmp/comstar_inject_out.txt -w '%{http_code}' -X POST "$INJECT" \
    -H 'Content-Type: application/json' \
    ${ADMIN_TOKEN:+-H "X-Comstar-Lan-Token: $ADMIN_TOKEN"} \
    -d "$1")"
  if [[ "$code" != "200" ]]; then
    log "WARN inject HTTP $code $(cat /tmp/comstar_inject_out.txt 2>/dev/null || true)"
  fi
}

bridge_since_mark() {
  local mark="$1"
  local now ago
  now="$(now_epoch)"
  ago=$((now - mark + 1))
  (( ago < 1 )) && ago=1
  journalctl --user -u comstar-bridge --since "${ago} sec ago" --no-pager 2>/dev/null || true
}

wait_new() {
  local mark="$1"
  local pattern="$2"
  local seconds="${3:-90}"
  local i=0
  while (( i < seconds )); do
    if bridge_since_mark "$mark" | grep -qE "$pattern"; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

wait_fresh_listen() {
  local mark="$1"
  local seconds="${2:-50}"
  wait_new "$mark" 'Engaged mic armed|listen_promote' "$seconds"
}

# Direct MCP probe first — fails fast if Ada vision is down.
mcp_probe() {
  local url="${COMSTAR_VISION_MCP_URL:-http://10.0.10.16:8793/mcp}"
  log "=== MCP health/probe $url ==="
  if ! curl -sf -m 5 "${url%/mcp}/health" >/dev/null 2>&1 && \
     ! curl -sf -m 5 "http://10.0.10.16:8793/health" >/dev/null; then
    bad "vision MCP health unreachable"
    return 0
  fi
  local root="$ROOT"
  if [[ -d "$root/terminal/bridge" ]]; then
    (
      cd "$root/terminal/bridge"
      export COMSTAR_VISION_MCP_URL="${COMSTAR_VISION_MCP_URL:-http://10.0.10.16:8793/mcp}"
      if dart run tool/vision_visit_e2e.dart; then
        ok "dart vision_visit_e2e"
      else
        bad "dart vision_visit_e2e"
      fi
    )
  else
    bad "bridge tree missing for dart e2e"
  fi
}

ask() {
  local prompt="$1"
  local since_token="$2"
  log "=== $prompt (expect since=$since_token) ==="

  local arm_mark
  arm_mark="$(now_epoch)"
  if ! wait_fresh_listen "$arm_mark" 55; then
    bad "$since_token — not listening after arm_mark=$arm_mark"
    return 0
  fi
  sleep 0.8

  local ask_mark
  ask_mark="$(now_epoch)"
  inject_json '{"event":"SpeechStart"}'
  sleep 0.25
  python3 - "$prompt" <<'PY' | curl -sS -X POST "$INJECT" \
    -H 'Content-Type: application/json' \
    ${ADMIN_TOKEN:+-H "X-Comstar-Lan-Token: $ADMIN_TOKEN"} \
    --data-binary @- >/dev/null
import json, sys
print(json.dumps({"event": "TranscriptReady", "text": sys.argv[1]}))
PY

  # Must hit bridge-local vision path with a real spoken line — not AO fallback.
  if wait_new "$ask_mark" "vision_visit_ok.*\"since\":\"$since_token\"" 90; then
    local line
    line="$(bridge_since_mark "$ask_mark" | grep -E "vision_visit_ok.*$since_token" | tail -1)"
    # Reject empty / missing preview
    if echo "$line" | grep -qE '"chars":[1-9]'; then
      ok "$since_token — ${line:0:280}"
    else
      bad "$since_token — vision_visit_ok but empty chars: ${line:0:200}"
    fi
  else
    bad "$since_token — no vision_visit_ok (AO/timeout?)"
    bridge_since_mark "$ask_mark" \
      | grep -E 'vision_visit|direct_agent|stt_result|dev_inject|fallback' | tail -25 || true
  fi

  local drain_mark
  drain_mark="$(now_epoch)"
  wait_new "$drain_mark" 'speak_ended' 70 || true
  sleep 1
}

ask_last_seen() {
  local prompt="$1"
  local name="$2"
  log "=== $prompt (expect personLastSeen name=$name) ==="

  local arm_mark
  arm_mark="$(now_epoch)"
  if ! wait_fresh_listen "$arm_mark" 55; then
    bad "last_seen_$name — not listening"
    return 0
  fi
  sleep 0.8

  local ask_mark
  ask_mark="$(now_epoch)"
  inject_json '{"event":"SpeechStart"}'
  sleep 0.25
  python3 - "$prompt" <<'PY' | curl -sS -X POST "$INJECT" \
    -H 'Content-Type: application/json' \
    ${ADMIN_TOKEN:+-H "X-Comstar-Lan-Token: $ADMIN_TOKEN"} \
    --data-binary @- >/dev/null
import json, sys
print(json.dumps({"event": "TranscriptReady", "text": sys.argv[1]}))
PY

  if wait_new "$ask_mark" "vision_visit_ok.*personLastSeen" 60; then
    local line
    line="$(bridge_since_mark "$ask_mark" | grep -E "vision_visit_ok.*personLastSeen" | tail -1)"
    if echo "$line" | grep -qiE 'driveway' && echo "$line" | grep -qiE '5:1[35]'; then
      bad "last_seen_$name — driveway 5:13/5:15 misattribute: ${line:0:280}"
    else
      ok "last_seen_$name — ${line:0:280}"
    fi
  else
    bad "last_seen_$name — no vision_visit_ok personLastSeen"
    bridge_since_mark "$ask_mark" \
      | grep -E 'vision_visit|direct_agent|stt_result|Adna|Zlatko' | tail -25 || true
  fi

  local drain_mark
  drain_mark="$(now_epoch)"
  wait_new "$drain_mark" 'speak_ended' 70 || true
  sleep 1
}

mcp_probe

log "Engage face for $USERID…"
local_mark="$(now_epoch)"
inject_json '{"event":"ExitSleep"}'
sleep 1
inject_json "{\"event\":\"FaceRecognized\",\"userid\":\"$USERID\",\"confidence\":0.99}"

if ! wait_fresh_listen "$local_mark" 90; then
  log "WARN: mic not armed after greeter; PlaybackEnded fallback"
  inject_json '{"event":"PlaybackEnded"}'
  local_mark="$(now_epoch)"
  wait_fresh_listen "$local_mark" 40 || true
fi

ask "Who was in my driveway today?" today
ask "Who was in my driveway yesterday?" yesterday
ask_last_seen "When was the last time you saw Adna?" Adna

log ""
log "Results: PASS=$PASS FAIL=$FAIL"
bridge_since_mark "$local_mark" \
  | grep -E 'vision_visit_ok|vision_visit_failed|vision_visit_intent|direct_agent_failed' | tail -40 || true

[[ "$FAIL" -eq 0 ]]
