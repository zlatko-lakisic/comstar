#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

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
  fi
else
  echo "SKIP ssh (not installed)"
fi

echo "--------------"
echo "Passed: $PASS  Failed: $FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
