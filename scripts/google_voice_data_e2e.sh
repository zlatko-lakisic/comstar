#!/usr/bin/env bash
# Live read-only Google voice intents via inject + local REST on the Pi.
# Uses the OAuth token already linked for COMSTAR (device pairing).
#   ssh comstar 'bash /opt/comstar/src/scripts/google_voice_data_e2e.sh'
set -euo pipefail

INJECT="${INJECT_URL:-http://127.0.0.1:8781/admin/inject}"
USERID="${COMSTAR_USER:-zlatko}"
PASS=0
FAIL=0

log() { printf '%s\n' "$*"; }
ok() { PASS=$((PASS + 1)); log "PASS  $*"; }
bad() { FAIL=$((FAIL + 1)); log "FAIL  $*"; }

now_epoch() { date +%s; }

inject_json() {
  curl -sS -X POST "$INJECT" -H 'Content-Type: application/json' -d "$1" >/dev/null
}

# journalctl on Pi often rejects ISO stamps; use relative "Ns ago" from a mark.
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
  local seconds="${3:-45}"
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

ask() {
  local prompt="$1"
  local expect_kind="$2"
  log "=== $prompt (expect $expect_kind) ==="

  local arm_mark
  arm_mark="$(now_epoch)"
  if ! wait_fresh_listen "$arm_mark" 55; then
    bad "$expect_kind — not listening after arm_mark=$arm_mark"
    return 0
  fi
  sleep 0.8

  local ask_mark
  ask_mark="$(now_epoch)"
  inject_json '{"event":"SpeechStart"}'
  sleep 0.25
  python3 - "$prompt" <<'PY' | curl -sS -X POST "$INJECT" -H 'Content-Type: application/json' --data-binary @- >/dev/null
import json, sys
print(json.dumps({"event": "TranscriptReady", "text": sys.argv[1]}))
PY

  if wait_new "$ask_mark" "google_data_ok.*\"kind\":\"$expect_kind\"" 35; then
    local line
    line="$(bridge_since_mark "$ask_mark" | grep -E "google_data_ok.*$expect_kind" | tail -1)"
    ok "$expect_kind — ${line:0:260}"
  else
    bad "$expect_kind — no google_data_ok"
    bridge_since_mark "$ask_mark" \
      | grep -E 'google_data|direct_agent|stt_result|dev_inject|followup' | tail -20 || true
  fi

  # Drain this turn's TTS, then require a *new* mic arm before the next ask.
  local drain_mark
  drain_mark="$(now_epoch)"
  wait_new "$drain_mark" 'speak_ended' 55 || true
  sleep 1
}

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

ask "What is on my Google Calendar today?" calendarToday
ask "List my Google calendars" calendarList
ask "What meetings do I have today?" calendarToday
ask "Show me my calendar schedule for today" calendarToday
ask "What is in my Google Drive?" driveList
ask "List my Google Drive files" driveList
ask "What is in my Gmail today?" gmailToday
ask "Any new emails in my inbox?" gmailToday

log ""
log "Results: PASS=$PASS FAIL=$FAIL"
bridge_since_mark "$local_mark" \
  | grep -E 'google_data_ok|google_data_failed|google_gmail_read' | tail -40 || true

[[ "$FAIL" -eq 0 ]]
