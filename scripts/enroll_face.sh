#!/usr/bin/env bash
# Capture N frames from the terminal camera and register a FreeIPA-bound face id
# with CodeProject.AI (ADR 0005).
#
# Usage: ./scripts/enroll_face.sh <ipa-uid> [n_frames=8]
#
# Env:
#   CPAI_URL                 CodeProject.AI base (default http://10.0.10.16:32168)
#   COMSTAR_CAMERA_SOURCE    V4L2 device (default /dev/video0)
#   COMSTAR_ENROLL_DIR       JPEG output dir
#   COMSTAR_LDAP_URL         e.g. ldap://ipa.example.com  (skip verify if unset + SKIP)
#   COMSTAR_LDAP_BIND_DN / COMSTAR_LDAP_BIND_PASSWORD / COMSTAR_LDAP_BASE_DN
#   COMSTAR_LDAP_FACE_ATTR   default comstarFaceId
#   COMSTAR_FACE_ID          override biometric id (default = ipa-uid)
#   COMSTAR_SKIP_LDAP=1      skip FreeIPA verify/bind (bring-up only)
set -euo pipefail

USERID="${1:-}"
N="${2:-8}"
CPAI_URL="${CPAI_URL:-http://10.0.10.16:32168}"
DEVICE="${COMSTAR_CAMERA_SOURCE:-${COMSTAR_CAMERA_DEVICE:-${COMSTAR_CAMERA_INPUT:-/dev/video0}}}"
OUTDIR="${COMSTAR_ENROLL_DIR:-/tmp/comstar-enroll-$USERID}"
FACE_ATTR="${COMSTAR_LDAP_FACE_ATTR:-comstarFaceId}"
FACE_ID="${COMSTAR_FACE_ID:-}"
SKIP_LDAP="${COMSTAR_SKIP_LDAP:-0}"

if [[ -z "$USERID" ]]; then
  echo "usage: $0 <ipa-uid> [n_frames]" >&2
  exit 2
fi

FACE_ID="${FACE_ID:-$USERID}"

ensure_ldap_binding() {
  if [[ "$SKIP_LDAP" == "1" ]]; then
    echo "COMSTAR_SKIP_LDAP=1 — skipping FreeIPA verify; CPAI userid=$FACE_ID"
    return 0
  fi
  if [[ -z "${COMSTAR_LDAP_URL:-}" || -z "${COMSTAR_LDAP_BASE_DN:-}" ]]; then
    echo "FreeIPA not configured (set COMSTAR_LDAP_URL + COMSTAR_LDAP_BASE_DN," >&2
    echo "or COMSTAR_SKIP_LDAP=1 for bring-up without directory)." >&2
    exit 2
  fi
  if ! command -v ldapsearch >/dev/null 2>&1; then
    echo "ldapsearch not found; install openldap-clients or set COMSTAR_SKIP_LDAP=1" >&2
    exit 2
  fi

  local auth=()
  if [[ -n "${COMSTAR_LDAP_BIND_DN:-}" ]]; then
    auth=(-x -D "$COMSTAR_LDAP_BIND_DN")
    if [[ -n "${COMSTAR_LDAP_BIND_PASSWORD:-}" ]]; then
      auth+=(-w "$COMSTAR_LDAP_BIND_PASSWORD")
    fi
  else
    auth=(-Y GSSAPI)
  fi

  echo "Verifying IPA uid=$USERID under ${COMSTAR_LDAP_BASE_DN}…"
  local entry
  entry="$(ldapsearch "${auth[@]}" -H "$COMSTAR_LDAP_URL" -b "$COMSTAR_LDAP_BASE_DN" \
    -LLL "(uid=$USERID)" dn uid "$FACE_ATTR" 2>/dev/null || true)"
  if [[ -z "$entry" ]]; then
    echo "No FreeIPA user uid=$USERID in ${COMSTAR_LDAP_BASE_DN}" >&2
    exit 1
  fi

  local current
  current="$(printf '%s\n' "$entry" | awk -v a="$FACE_ATTR" 'tolower($1)==tolower(a)":"{print $2; exit}')"
  if [[ -n "$current" && "$current" == "$FACE_ID" ]]; then
    echo "LDAP $FACE_ATTR already set to $FACE_ID"
    return 0
  fi

  if ! command -v ldapmodify >/dev/null 2>&1; then
    echo "ldapmodify not found; set $FACE_ATTR=$FACE_ID on uid=$USERID manually" >&2
    exit 1
  fi

  local dn
  dn="$(printf '%s\n' "$entry" | awk '/^dn:/{sub(/^dn: /,""); print; exit}')"
  if [[ -z "$dn" ]]; then
    echo "Could not parse DN for uid=$USERID" >&2
    exit 1
  fi

  echo "Setting $FACE_ATTR=$FACE_ID on $dn"
  local ldif
  ldif="$(mktemp)"
  if [[ -n "$current" ]]; then
    cat >"$ldif" <<EOF
dn: $dn
changetype: modify
replace: $FACE_ATTR
$FACE_ATTR: $FACE_ID
EOF
  else
    # Best-effort: add auxiliary class if missing, then the face attr.
    cat >"$ldif" <<EOF
dn: $dn
changetype: modify
add: objectClass
objectClass: comstarPerson
-
add: $FACE_ATTR
$FACE_ATTR: $FACE_ID
EOF
    if ! ldapmodify "${auth[@]}" -H "$COMSTAR_LDAP_URL" -f "$ldif" 2>/tmp/comstar-ldapmodify.err; then
      # objectClass may already be present — try attr-only add
      cat >"$ldif" <<EOF
dn: $dn
changetype: modify
add: $FACE_ATTR
$FACE_ATTR: $FACE_ID
EOF
      ldapmodify "${auth[@]}" -H "$COMSTAR_LDAP_URL" -f "$ldif"
    fi
    rm -f "$ldif"
    return 0
  fi
  ldapmodify "${auth[@]}" -H "$COMSTAR_LDAP_URL" -f "$ldif"
  rm -f "$ldif"
}

ensure_ldap_binding

mkdir -p "$OUTDIR"
echo "Capturing $N frames from $DEVICE → $OUTDIR (CPAI userid=$FACE_ID)"
for i in $(seq 1 "$N"); do
  ffmpeg -hide_banner -loglevel error -y -f v4l2 -video_size 640x480 -i "$DEVICE" \
    -vframes 1 "$OUTDIR/$(printf '%02d' "$i").jpg"
  sleep 0.4
done

args=(-F "userid=$FACE_ID")
n=1
for f in "$OUTDIR"/*.jpg; do
  args+=(-F "image${n}=@$f")
  n=$((n + 1))
done

echo "Registering faceId=$FACE_ID (IPA uid=$USERID) at $CPAI_URL"
/usr/bin/curl -sS -m 60 -X POST "$CPAI_URL/v1/vision/face/register" "${args[@]}" | tee /tmp/enroll_result.json
echo
/usr/bin/curl -sS -m 10 -X POST "$CPAI_URL/v1/vision/face/list"
echo
