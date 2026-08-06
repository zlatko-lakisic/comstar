#!/usr/bin/env bash
# COMSTAR M9 soak collector — run on the Pi (detached).
# Collects unit health, RSS, fds, wake/false-wake signals, CPAI/AO reachability.
#
# Usage:
#   ./scripts/comstar_soak.sh                 # 24h default
#   COMSTAR_SOAK_HOURS=1 ./scripts/comstar_soak.sh
#   COMSTAR_SOAK_OUT=~/comstar-soak ./scripts/comstar_soak.sh
#   make soak                                 # nohup on the Pi via SSH
set -euo pipefail

HOURS="${COMSTAR_SOAK_HOURS:-24}"
OUT="${COMSTAR_SOAK_OUT:-$HOME/.local/share/comstar/soak/$(date +%Y%m%d-%H%M%S)}"
INTERVAL="${COMSTAR_SOAK_INTERVAL_SEC:-60}"
END=$(( $(date +%s) + HOURS * 3600 ))

mkdir -p "$OUT"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# Long-running units (is-active == active). Health is a oneshot — probe the timer.
UNITS=(comstar-bridge comstar-audio comstar-kiosk comstar-memory comstar-stt comstar-tts)
TIMERS=(comstar-health.timer)

unit_state() {
  # Never append a second word via `|| echo` — that breaks JSON when the unit
  # is inactive/failed (systemctl still prints the state on stdout).
  local st
  st=$(systemctl --user is-active "$1" 2>/dev/null || true)
  [[ -n "$st" ]] || st=missing
  # Collapse whitespace/newlines just in case.
  printf '%s' "${st//$'\n'/ }"
}

echo "{\"ts\":$(date +%s)000,\"evt\":\"soak_start\",\"hours\":$HOURS,\"out\":\"$OUT\"}" | tee -a "$OUT/events.jsonl"

sample() {
  local ts now
  ts=$(date +%s)000
  now=$(date -Iseconds)
  local line="{\"ts\":$ts,\"at\":\"$now\""
  local u st
  for u in "${UNITS[@]}"; do
    st=$(unit_state "$u")
    line+=",\"$u\":\"$st\""
  done
  for u in "${TIMERS[@]}"; do
    st=$(unit_state "$u")
    # Key without .timer suffix for stable summary fields.
    line+=",\"${u%.timer}_timer\":\"$st\""
  done
  # bridge RSS / fds if running
  local pid
  pid=$(systemctl --user show comstar-bridge -p MainPID --value 2>/dev/null || echo 0)
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    local rss fds
    rss=$(awk '/VmRSS/{print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)
    fds=$(ls "/proc/$pid/fd" 2>/dev/null | wc -l | tr -d ' ')
    line+=",\"bridge_pid\":$pid,\"bridge_rss_kb\":$rss,\"bridge_fds\":$fds"
  fi
  # CPAI / AO / memory / speech probes
  local cpai ao mem
  cpai=$(curl -sf -m 2 -X POST http://10.0.10.16:32168/v1/vision/detection \
    -H 'Content-Type: application/json' -d '{}' >/dev/null && echo ok || echo down)
  ao=$(curl -sf -m 2 http://10.0.10.16:8765/health >/dev/null && echo ok || echo down)
  mem=$(curl -sf -m 2 http://127.0.0.1:8792/health >/dev/null && echo ok || echo down)
  line+=",\"cpai\":\"$cpai\",\"ao\":\"$ao\",\"memory\":\"$mem\""
  # temp
  local temp
  temp=$(vcgencmd measure_temp 2>/dev/null | sed 's/[^0-9.]//g' || echo null)
  [[ -n "$temp" ]] || temp=null
  line+=",\"temp_c\":${temp}}"
  echo "$line" >> "$OUT/samples.jsonl"
}

# Count wake / force_wake / sleep_wake rejects since soak start via journal cursor
journalctl --user -u comstar-bridge -u comstar-audio -n 0 -q --show-cursor 2>/dev/null \
  | awk '{print $NF}' > "$OUT/journal.cursor" || true

while [[ $(date +%s) -lt $END ]]; do
  sample
  sleep "$INTERVAL"
done

# Summarize wake events
CURSOR=$(cat "$OUT/journal.cursor" 2>/dev/null || true)
ARGS=(--user -u comstar-bridge -u comstar-audio --no-pager)
if [[ -n "${CURSOR:-}" ]]; then
  ARGS+=(--after-cursor "$CURSOR")
fi
journalctl "${ARGS[@]}" 2>/dev/null | tee "$OUT/journal-excerpt.txt" >/dev/null || true
force=$(grep -c '"evt":"force_wake"' "$OUT/journal-excerpt.txt" 2>/dev/null || true)
reject=$(grep -cE 'sleep_wake_stt.*"accepted":false|"accepted":false' "$OUT/journal-excerpt.txt" 2>/dev/null || true)
restarts=$(grep -c 'Started comstar-' "$OUT/journal-excerpt.txt" 2>/dev/null || true)
force=${force:-0}
reject=${reject:-0}
restarts=${restarts:-0}

python3 - <<PY | tee "$OUT/summary.json"
import json, pathlib
out = pathlib.Path("$OUT")
samples = []
p = out / "samples.jsonl"
if p.exists():
    for line in p.read_text().splitlines():
        try:
            samples.append(json.loads(line))
        except Exception:
            pass
rss = [s.get("bridge_rss_kb") for s in samples if s.get("bridge_rss_kb")]
fds = [s.get("bridge_fds") for s in samples if s.get("bridge_fds")]
def flat(xs):
    xs = [x for x in xs if isinstance(x, (int, float))]
    if not xs:
        return None
    return {"min": min(xs), "max": max(xs), "last": xs[-1],
            "delta_pct": round(100 * (xs[-1] - xs[0]) / max(xs[0], 1), 2)}
summary = {
    "hours": float("$HOURS"),
    "samples": len(samples),
    "force_wake_events": int("$force" or 0),
    "wake_reject_lines": int("$reject" or 0),
    "unit_start_lines": int("$restarts" or 0),
    "bridge_rss_kb": flat(rss),
    "bridge_fds": flat(fds),
    "cpai_down": sum(1 for s in samples if s.get("cpai") == "down"),
    "ao_down": sum(1 for s in samples if s.get("ao") == "down"),
    "memory_down": sum(1 for s in samples if s.get("memory") == "down"),
    "kiosk_non_active": sum(1 for s in samples if s.get("comstar-kiosk") not in (None, "active")),
    "health_timer_non_active": sum(
        1 for s in samples if s.get("comstar-health_timer") not in (None, "active")
    ),
}
print(json.dumps(summary, indent=2))
PY

echo "{\"ts\":$(date +%s)000,\"evt\":\"soak_end\",\"out\":\"$OUT\"}" | tee -a "$OUT/events.jsonl"
echo "soak complete → $OUT"
