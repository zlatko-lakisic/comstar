#!/usr/bin/env bash
# TTS.0.1 / TTS.0.2 — run Kokoro bench on the AI server; append BASELINES.md.
#
# Usage:
#   ./scripts/verify_tts.sh
#   AI_HOST=zlatko.lakisic@10.0.10.16 ./scripts/verify_tts.sh
#   KOKORO_BENCH_MODE=idle ./scripts/verify_tts.sh
#
# Requires SSH to the AI server and /var/lib/agentic/venv-tts with sherpa-onnx.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AI_HOST="${AI_HOST:-zlatko.lakisic@10.0.10.16}"
REMOTE_DIR="${REMOTE_DIR:-/tmp/comstar-kokoro-bench}"
PY="${REMOTE_PY:-/var/lib/agentic/venv-tts/bin/python}"
MODEL_DIR="${COMSTAR_KOKORO_MODEL_DIR:-/home/zlatko.lakisic/agentic-speech-models/tts-kokoro}"
PROVIDER="${COMSTAR_TTS_PROVIDER:-cpu}"
MODE="${KOKORO_BENCH_MODE:-both}"
CPAI_URL="${CPAI_URL:-http://127.0.0.1:32168}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOCAL_JSON="$ROOT/docs/fixtures/kokoro_bench_${STAMP}.json"
LOCAL_LOG="$ROOT/docs/fixtures/kokoro_bench_${STAMP}.log"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need ssh
need scp
need python3

mkdir -p "$ROOT/docs/fixtures"

echo "== TTS.0 Kokoro verify =="
echo "AI_HOST=$AI_HOST"
echo "MODEL_DIR=$MODEL_DIR"
echo "PROVIDER=$PROVIDER MODE=$MODE"
echo "CPAI_URL=$CPAI_URL"

echo
echo "-- sync spike to $AI_HOST:$REMOTE_DIR --"
ssh "$AI_HOST" "mkdir -p '$REMOTE_DIR'"
scp -q "$ROOT/spike/kokoro_bench.py" "$AI_HOST:$REMOTE_DIR/kokoro_bench.py"

echo
echo "-- remote bench (this can take several minutes) --"
ssh "$AI_HOST" bash -s <<REMOTE
set -euo pipefail
export COMSTAR_KOKORO_MODEL_DIR='$MODEL_DIR'
export COMSTAR_TTS_PROVIDER='$PROVIDER'
export KOKORO_BENCH_MODE='$MODE'
export CPAI_URL='$CPAI_URL'
export COMSTAR_TTS_KOKORO_SID='${COMSTAR_TTS_KOKORO_SID:-0}'
export COMSTAR_TTS_THREADS='${COMSTAR_TTS_THREADS:-4}'
export KOKORO_BENCH_REPEATS='${KOKORO_BENCH_REPEATS:-5}'
export KOKORO_BENCH_WARMUP='${KOKORO_BENCH_WARMUP:-1}'
'$PY' '$REMOTE_DIR/kokoro_bench.py' \
  --json-out '$REMOTE_DIR/result.json' \
  2>'$REMOTE_DIR/stderr.log' | tee '$REMOTE_DIR/stdout.log'
REMOTE


scp -q "$AI_HOST:$REMOTE_DIR/result.json" "$LOCAL_JSON"
scp -q "$AI_HOST:$REMOTE_DIR/stdout.log" "$LOCAL_LOG" || true
scp -q "$AI_HOST:$REMOTE_DIR/stderr.log" "$ROOT/docs/fixtures/kokoro_bench_${STAMP}.stderr.log" || true

echo
echo "-- write BASELINES.md section from $LOCAL_JSON --"
python3 "$ROOT/scripts/write_kokoro_baselines.py" \
  --json "$LOCAL_JSON" \
  --baselines "$ROOT/docs/BASELINES.md" \
  --stamp "$STAMP" \
  --host "$AI_HOST"

echo
echo "Done."
echo "JSON: $LOCAL_JSON"
echo "BASELINES: $ROOT/docs/BASELINES.md"
echo
echo "Next (still TTS.0, not product code):"
echo "  - TTS.0.3 voice listen on Pi speakers"
echo "  - TTS.0.4 sample-rate decision → CONTRACTS §2"
echo "  - ADR docs/adr/0008-tts-engine.md"
echo "  - CONTRACTS §6 streaming paragraph (from BASELINES finding)"
