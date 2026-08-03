#!/usr/bin/env bash
# Capture N frames from the terminal camera and register a userid with CodeProject.AI.
# Usage: ./scripts/enroll_face.sh <userid> [n_frames=8]
set -euo pipefail

USERID="${1:-}"
N="${2:-8}"
CPAI_URL="${CPAI_URL:-http://10.0.10.16:32168}"
DEVICE="${COMSTAR_CAMERA_SOURCE:-${COMSTAR_CAMERA_DEVICE:-${COMSTAR_CAMERA_INPUT:-/dev/video0}}}"
OUTDIR="${COMSTAR_ENROLL_DIR:-/tmp/comstar-enroll-$USERID}"

if [[ -z "$USERID" ]]; then
  echo "usage: $0 <userid> [n_frames]" >&2
  exit 2
fi

mkdir -p "$OUTDIR"
echo "Capturing $N frames from $DEVICE → $OUTDIR"
for i in $(seq 1 "$N"); do
  ffmpeg -hide_banner -loglevel error -y -f v4l2 -video_size 640x480 -i "$DEVICE" \
    -vframes 1 "$OUTDIR/$(printf '%02d' "$i").jpg"
  sleep 0.4
done

args=(-F "userid=$USERID")
n=1
for f in "$OUTDIR"/*.jpg; do
  args+=(-F "image${n}=@$f")
  n=$((n + 1))
done

echo "Registering $USERID at $CPAI_URL"
/usr/bin/curl -sS -m 60 -X POST "$CPAI_URL/v1/vision/face/register" "${args[@]}" | tee /tmp/enroll_result.json
echo
/usr/bin/curl -sS -m 10 -X POST "$CPAI_URL/v1/vision/face/list"
echo
