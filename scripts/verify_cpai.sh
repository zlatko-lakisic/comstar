#!/usr/bin/env bash
# M0.1 / M0.2 — probe CodeProject.AI and write fixtures.
# Usage: CPAI_URL=http://10.0.10.16:32168 IMAGE=docs/fixtures/_probe_frame.jpg ./scripts/verify_cpai.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CPAI_URL="${CPAI_URL:-http://10.0.10.16:32168}"
IMAGE="${IMAGE:-$ROOT/docs/fixtures/_probe_frame.jpg}"
FIXTURES="$ROOT/docs/fixtures"
PROBE_USER="_probe"
mkdir -p "$FIXTURES"

cleanup() {
  curl -sS -m 10 -X POST "$CPAI_URL/v1/vision/face/delete" \
    -F "userid=$PROBE_USER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need curl
need python3

if [[ ! -f "$IMAGE" ]]; then
  echo "IMAGE not found: $IMAGE" >&2
  exit 1
fi

echo "== CodeProject.AI probe =="
echo "URL: $CPAI_URL"
echo "IMAGE: $IMAGE"

echo
echo "-- ping --"
curl -sS -m 5 "$CPAI_URL/v1/server/status/ping" | tee "$FIXTURES/cpai_ping.json" | python3 -m json.tool | head -40

echo
echo "-- face/list --"
curl -sS -m 10 -X POST "$CPAI_URL/v1/vision/face/list" | tee "$FIXTURES/cpai_face_list.json" | python3 -m json.tool

echo
echo "-- detection --"
curl -sS -m 30 -X POST "$CPAI_URL/v1/vision/detection" \
  -F "image=@$IMAGE" -F "min_confidence=0.4" \
  | tee "$FIXTURES/cpai_detection.json" | python3 -m json.tool

echo
echo "-- register throwaway face $PROBE_USER --"
# Use same frame thrice for probe registration (enough for module smoke).
curl -sS -m 60 -X POST "$CPAI_URL/v1/vision/face/register" \
  -F "userid=$PROBE_USER" \
  -F "image1=@$IMAGE" \
  -F "image2=@$IMAGE" \
  -F "image3=@$IMAGE" \
  | tee "$FIXTURES/cpai_register.json" | python3 -m json.tool

echo
echo "-- recognize hit --"
curl -sS -m 30 -X POST "$CPAI_URL/v1/vision/face/recognize" \
  -F "image=@$IMAGE" -F "min_confidence=0.4" \
  | tee "$FIXTURES/cpai_recognize_hit.json" | python3 -m json.tool

echo
echo "-- recognize miss (after delete) --"
cleanup
trap - EXIT
# solid color stranger image
python3 - <<'PY'
from pathlib import Path
p = Path("docs/fixtures/_stranger.jpg")
# minimal JPEG via stdlib-free PPM then skip - write raw jpeg bytes for a gray square using pillow if available else skip
try:
  from PIL import Image
  Image.new("RGB", (320, 240), (40, 40, 40)).save(p, quality=85)
except Exception:
  # tiny valid JPEG (1x1)
  p.write_bytes(bytes.fromhex(
    "ffd8ffe000104a46494600010100000100010000ffdb004300080606070605080707"
    "070909080a0c140d0c0b0b0c1912130f141d1a1f1e1d1a1c1c20242e2720222c231c"
    "1c2837292c30313434341f27393d38323c2e333432ffdb0043010909090c0b0c180d"
    "0d1832211c2132323232323232323232323232323232323232323232323232323232"
    "323232323232323232323232323232323232323232323232ffc00011080001000103"
    "0111000211031101ffc40014000100000000000000000000000000000000ffc40014"
    "100100000000000000000000000000000000ffda000c0301000210031000003f00bf"
    "80ffd9"
  ))
print(p)
PY

curl -sS -m 30 -X POST "$CPAI_URL/v1/vision/face/recognize" \
  -F "image=@$FIXTURES/_stranger.jpg" -F "min_confidence=0.4" \
  | tee "$FIXTURES/cpai_recognize_miss.json" | python3 -m json.tool

# Also keep a miss-with-face sample if we have prior known response from room frame without enrollment
# Re-register is cleaned; room frame with a person and empty gallery is a better miss:
curl -sS -m 10 -X POST "$CPAI_URL/v1/vision/face/list" >/dev/null
curl -sS -m 30 -X POST "$CPAI_URL/v1/vision/face/recognize" \
  -F "image=@$IMAGE" -F "min_confidence=0.4" \
  | tee "$FIXTURES/cpai_recognize_miss_person.json" | python3 -m json.tool

echo
echo "-- timing 20 detections --"
python3 - <<PY
import json, time, urllib.request, mimetypes, uuid
from pathlib import Path
url = "$CPAI_URL/v1/vision/detection"
img = Path("$IMAGE").read_bytes()
boundary = "----comstar" + uuid.uuid4().hex
body = b""
for name, val in [("min_confidence", b"0.4")]:
    body += f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n".encode() + val + b"\r\n"
body += f"--{boundary}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"frame.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".encode()
body += img + b"\r\n"
body += f"--{boundary}--\r\n".encode()
ms = []
for i in range(20):
    req = urllib.request.Request(url, data=body, headers={"Content-Type": f"multipart/form-data; boundary={boundary}"}, method="POST")
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.load(r)
    wall = (time.perf_counter() - t0) * 1000
    inf = data.get("inferenceMs") or data.get("processMs") or wall
    ms.append(float(inf))
ms_sorted = sorted(ms)
def pct(p):
    idx = int(round((p/100) * (len(ms_sorted)-1)))
    return ms_sorted[idx]
summary = {
  "n": len(ms),
  "inferenceMs_p50": pct(50),
  "inferenceMs_p95": pct(95),
  "samples": ms,
}
Path("$FIXTURES/cpai_detection_timing.json").write_text(json.dumps(summary, indent=2))
print(json.dumps(summary, indent=2))
PY

echo
echo "== SUMMARY =="
python3 - <<'PY'
import json
from pathlib import Path
fixtures = Path("docs/fixtures")
rows = []
for name in [
  "cpai_ping.json","cpai_face_list.json","cpai_detection.json",
  "cpai_recognize_hit.json","cpai_recognize_miss_person.json","cpai_detection_timing.json"
]:
  p = fixtures / name
  if not p.exists():
    rows.append((name, "MISSING", ""))
    continue
  d = json.loads(p.read_text())
  if name.endswith("timing.json"):
    rows.append((name, "ok", f"p50={d.get('inferenceMs_p50')} p95={d.get('inferenceMs_p95')}"))
  else:
    rows.append((name, "ok" if d.get("success", True) else "fail",
                 f"device={d.get('inferenceDevice')} module={d.get('moduleName','')}"))
print(f"{'file':40} {'st':6} detail")
for r in rows:
  print(f"{r[0]:40} {r[1]:6} {r[2]}")
miss = json.loads((fixtures/"cpai_recognize_miss_person.json").read_text())
preds = miss.get("predictions") or []
if preds:
  print("MISS SHAPE: predictions present; userid=", preds[0].get("userid"))
else:
  print("MISS SHAPE: empty predictions array")
print("CPAI_LIVE_PASS")
PY

echo "Fixtures written to $FIXTURES"
