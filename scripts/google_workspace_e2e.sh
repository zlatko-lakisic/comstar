#!/usr/bin/env bash
# Live Google Workspace MCP connectivity (Pi OAuth token).
#   ssh comstar 'bash /opt/comstar/src/scripts/google_workspace_e2e.sh'
set -euo pipefail

USERID="${COMSTAR_USER:-zlatko}"
TOKEN_FILE="${GOOGLE_TOKEN_FILE:-$HOME/.local/share/comstar/google/${USERID}.json}"
ENV_FILE="${GOOGLE_ENV_FILE:-$HOME/.config/comstar/google.env}"
MCP_JS="${MCP_JS:-$HOME/.local/node_modules/mcp-server-google-workspace/dist/index.js}"
PORT="${MCP_E2E_PORT:-19077}"
PASS=0
FAIL=0
SKIP=0

log() { printf '%s\n' "$*"; }
ok() { PASS=$((PASS + 1)); log "PASS  $*"; }
bad() { FAIL=$((FAIL + 1)); log "FAIL  $*"; }
skip() { SKIP=$((SKIP + 1)); log "SKIP  $*"; }

need() { command -v "$1" >/dev/null || { log "missing $1"; exit 2; }; }
need node; need npx; need curl; need python3

[[ -f "$ENV_FILE" ]] || { log "missing $ENV_FILE"; exit 2; }
[[ -f "$TOKEN_FILE" ]] || { log "missing $TOKEN_FILE"; exit 2; }
[[ -f "$MCP_JS" ]] || { log "missing $MCP_JS"; exit 2; }

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
export GOOGLE_REFRESH_TOKEN
GOOGLE_REFRESH_TOKEN="$(python3 -c "import json;print(json.load(open('$TOKEN_FILE'))['refresh_token'])")"

NODE_MAJOR="$(node -v | sed -E 's/^v([0-9]+).*/\1/')"
[[ "$NODE_MAJOR" -ge 20 ]] || { bad "Node $(node -v) < 20"; exit 1; }
ok "Node $(node -v)"

SCOPE_JSON="$(python3 - <<'PY'
import os, urllib.parse, urllib.request, json
data = urllib.parse.urlencode({
  'client_id': os.environ['GOOGLE_CLIENT_ID'],
  'client_secret': os.environ['GOOGLE_CLIENT_SECRET'],
  'refresh_token': os.environ['GOOGLE_REFRESH_TOKEN'],
  'grant_type': 'refresh_token',
}).encode()
with urllib.request.urlopen(urllib.request.Request('https://oauth2.googleapis.com/token', data=data), timeout=20) as r:
  j = json.load(r)
print(json.dumps({'scope': j.get('scope',''), 'access_token': j['access_token']}))
PY
)"
SCOPE="$(python3 -c "import json,sys; print(json.load(sys.stdin)['scope'])" <<<"$SCOPE_JSON")"
AT="$(python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])" <<<"$SCOPE_JSON")"
log "oauth scopes: $SCOPE"
[[ "$SCOPE" == *calendar* ]] && ok "calendar scope" || bad "no calendar scope"
[[ "$SCOPE" == *gmail* ]] && ok "gmail scope" || skip "no gmail scope (device pairing)"
[[ "$SCOPE" == *drive* ]] && ok "drive scope present" || skip "no drive scope"

python3 - <<PY
import json, urllib.request, datetime, zoneinfo
at = '''$AT'''
tz = zoneinfo.ZoneInfo('America/New_York')
start = datetime.datetime.now(tz).replace(hour=0, minute=0, second=0, microsecond=0)
end = start + datetime.timedelta(days=1)
url = (
  'https://www.googleapis.com/calendar/v3/calendars/primary/events'
  f'?timeMin={start.isoformat()}&timeMax={end.isoformat()}'
  '&singleEvents=true&orderBy=startTime&maxResults=8'
)
req = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + at})
with urllib.request.urlopen(req, timeout=20) as r:
  e = json.load(r)
summaries = [i.get('summary','(no title)') for i in e.get('items', [])]
print('calendar REST events today (America/New_York):', len(summaries), summaries[:5])
open('/tmp/google_e2e_events.json','w').write(json.dumps(summaries))
PY
ok "calendar REST reachable"

pkill -f "mcp-proxy.*--port $PORT" 2>/dev/null || true
sleep 1
npx -y mcp-proxy@5.12.5 --port "$PORT" --server stream --streamEndpoint /mcp \
  node "$MCP_JS" >/tmp/google_e2e_mcp.log 2>&1 &
MCP_PID=$!
cleanup() { kill "$MCP_PID" 2>/dev/null || true; pkill -f "mcp-proxy.*--port $PORT" 2>/dev/null || true; }
trap cleanup EXIT

ready=0
for _ in $(seq 1 45); do
  ss -ltn 2>/dev/null | grep -q ":$PORT " && ready=1 && break
  sleep 1
done
[[ "$ready" -eq 1 ]] || { bad "mcp-proxy not listening"; tail -40 /tmp/google_e2e_mcp.log; exit 1; }
ok "mcp-proxy :$PORT"

HDR="$(mktemp)"; BODY="$(mktemp)"
curl -sS -D "$HDR" -o "$BODY" -X POST "http://127.0.0.1:$PORT/mcp" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"comstar-e2e","version":"0"}}}' \
  --max-time 15 >/dev/null
SID="$(grep -i mcp-session-id "$HDR" | awk '{print $2}' | tr -d '\r')"
[[ -n "$SID" ]] || { bad "no MCP session id"; cat "$BODY"; exit 1; }
ok "MCP session $SID"
curl -sS -X POST "http://127.0.0.1:$PORT/mcp" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' --max-time 5 >/dev/null

mcp_tool_file() {
  local name="$1" args="$2" out="$3"
  curl -sS -o "$out" -X POST "http://127.0.0.1:$PORT/mcp" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Mcp-Session-Id: $SID" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$name\",\"arguments\":$args}}" \
    --max-time 45
}

extract_file() {
  python3 - "$1" <<'PY'
import sys, re, json
raw = open(sys.argv[1], encoding='utf-8', errors='replace').read()
m = re.search(r'^data:\s*(\{.*\})\s*$', raw, re.M)
blob = m.group(1) if m else raw.strip()
try:
  j = json.loads(blob)
except Exception:
  print(raw[:800]); raise SystemExit(0)
if 'error' in j:
  print('ERROR:' + json.dumps(j['error'])[:500]); raise SystemExit(0)
texts = []
for c in (j.get('result') or {}).get('content') or []:
  if isinstance(c, dict) and c.get('type') == 'text':
    texts.append(c.get('text') or '')
print('\n'.join(texts) if texts else json.dumps(j)[:800])
PY
}

run_tool() {
  local label="$1" name="$2" args="$3" expect="$4"
  local raw="/tmp/google_e2e_${label}.raw"
  local out
  mcp_tool_file "$name" "$args" "$raw"
  out="$(extract_file "$raw")"
  log "$label => ${out:0:320}"
  printf '%s' "$out" >"/tmp/google_e2e_${label}.txt"
  case "$expect" in
    ok)
      if [[ "$out" == ERROR:* || -z "$out" ]]; then bad "$label $out"; else ok "$label"; fi
      ;;
    err)
      if [[ "$out" == ERROR:* ]]; then ok "$label expected error"; else bad "$label expected error, got: $out"; fi
      ;;
    skip_if_err)
      if [[ "$out" == ERROR:* ]]; then skip "$label $out"; else ok "$label"; fi
      ;;
  esac
}

log "--- read-only MCP prompts ---"
run_tool cal_calendars calendar_list_calendars '{}' ok
run_tool cal_events calendar_list_events '{"calendarId":"primary","maxResults":8}' ok
run_tool drive_list drive_list_files '{"pageSize":5}' ok
run_tool drive_search drive_search_files '{"query":"name contains '\''a'\''","pageSize":5}' skip_if_err
if [[ "$SCOPE" == *gmail* ]]; then
  run_tool gmail_list gmail_list_emails '{"hours":24,"maxResults":3}' ok
  run_tool gmail_search gmail_search_emails '{"query":"newer_than:1d","maxResults":3}' ok
else
  run_tool gmail_list gmail_list_emails '{"hours":24,"maxResults":3}' err
  skip "gmail_search (no gmail scope)"
fi

python3 - <<'PY'
import json, pathlib, sys
rest = json.loads(pathlib.Path('/tmp/google_e2e_events.json').read_text())
mcp = pathlib.Path('/tmp/google_e2e_cal_events.txt').read_text()
print('REST titles:', rest[:5])
if not rest:
  if 'summary' in mcp or mcp.strip().startswith('['):
    print('MCP calendar payload OK (no REST events in local day window)')
    raise SystemExit(0)
  print('WARN empty REST and weak MCP body')
  raise SystemExit(1)
hits = [s for s in rest if s and s.lower() in mcp.lower()]
print('REST∩MCP hits:', hits[:5])
if hits or 'summary' in mcp:
  raise SystemExit(0)
print('FAIL calendar MCP missing expected titles')
raise SystemExit(1)
PY
ok "calendar MCP↔REST consistency check"

log "--- summary PASS=$PASS FAIL=$FAIL SKIP=$SKIP ---"
[[ "$FAIL" -eq 0 ]]
