#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
SKIP=0

check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "OK   $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL $name"
    FAIL=$((FAIL + 1))
  fi
}

probe_http() {
  local name="$1"
  local url="$2"
  if curl -fsS --connect-timeout 2 --max-time 4 "$url" >/dev/null 2>&1; then
    echo "OK   $name ($url)"
    PASS=$((PASS + 1))
  else
    echo "SKIP $name ($url unreachable)"
    SKIP=$((SKIP + 1))
  fi
}

echo "COMSTAR doctor"
echo "=============="

check "dart" command -v dart
check "python3" command -v python3

if command -v dart >/dev/null 2>&1; then
  echo "     dart $(dart --version 2>&1 | head -1)"
fi
if command -v python3 >/dev/null 2>&1; then
  echo "     python3 $(python3 --version 2>&1)"
fi

if command -v ssh >/dev/null 2>&1; then
  if ssh -o BatchMode=yes -o ConnectTimeout=3 comstar true 2>/dev/null; then
    echo "OK   ssh comstar"
    PASS=$((PASS + 1))
  else
    echo "SKIP ssh comstar (host unreachable or not configured)"
    SKIP=$((SKIP + 1))
  fi
else
  echo "SKIP ssh (not installed)"
  SKIP=$((SKIP + 1))
fi

echo "--------------"
echo "LAN services (skipped if unreachable)"
echo "--------------"

AO_URL="${COMSTAR_AO_URL:-http://10.0.10.16:8765}"
CPAI_URL="${COMSTAR_CPAI_URL:-http://10.0.10.16:32168}"
STT_URL="${COMSTAR_STT_URL:-http://127.0.0.1:8090}"

probe_http "AO Reach" "$AO_URL/health"
probe_http "CodeProject.AI" "$CPAI_URL/v1/server/status/ping"
probe_http "STT (local)" "$STT_URL/health"

echo "--------------"
echo "Passed: $PASS  Failed: $FAIL  Skipped: $SKIP"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
