#!/usr/bin/env bash
# Write Nextcloud app-password credentials for a COMSTAR userid.
# Usage:
#   export NEXTCLOUD_HOST=https://cloud.example
#   export NEXTCLOUD_USERNAME=zlatko
#   export NEXTCLOUD_PASSWORD='app-password-here'
#   bash scripts/nextcloud_pair.sh [userid]
set -euo pipefail

USERID="${1:-${COMSTAR_USER:-zlatko}}"
: "${NEXTCLOUD_HOST:?set NEXTCLOUD_HOST}"
: "${NEXTCLOUD_USERNAME:?set NEXTCLOUD_USERNAME}"
: "${NEXTCLOUD_PASSWORD:?set NEXTCLOUD_PASSWORD}"

ROOT="${COMSTAR_DATA_DIR:-$HOME/.local/share/comstar}/nextcloud"
mkdir -p "$ROOT"
chmod 700 "$ROOT"

STEM=$(echo "$USERID" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '_')
export NEXTCLOUD_HOST="${NEXTCLOUD_HOST%/}"
export COMSTAR_NC_FILE="$ROOT/${STEM}.json"

python3 - <<'PY'
import json, os, datetime
path = os.environ["COMSTAR_NC_FILE"]
payload = {
  "host": os.environ["NEXTCLOUD_HOST"],
  "username": os.environ["NEXTCLOUD_USERNAME"],
  "app_password": os.environ["NEXTCLOUD_PASSWORD"],
  "updated_at": datetime.datetime.now(datetime.timezone.utc).strftime(
      "%Y-%m-%dT%H:%M:%SZ"
  ),
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(payload, f)
    f.write("\n")
print(f"Wrote {path} (host={payload['host']} user={payload['username']})")
PY

chmod 600 "$COMSTAR_NC_FILE"
SHORT="${STEM%%_*}"
if [[ "$SHORT" != "$STEM" && -n "$SHORT" ]]; then
  cp "$COMSTAR_NC_FILE" "$ROOT/${SHORT}.json"
  chmod 600 "$ROOT/${SHORT}.json"
fi
