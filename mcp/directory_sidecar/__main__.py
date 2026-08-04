"""COMSTAR directory sidecar — FreeIPA face/voice id → uid resolve (ADR 0005)."""

from __future__ import annotations

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, urlparse

try:
    from ldap3 import ALL, Connection, Server
    from ldap3.core.exceptions import LDAPException
except ImportError:  # pragma: no cover
    print("ldap3 required: pip install -r directory_sidecar/requirements.txt", file=sys.stderr)
    raise


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


LDAP_URL = _env("COMSTAR_LDAP_URL")
BIND_DN = _env("COMSTAR_LDAP_BIND_DN")
BIND_PASSWORD = _env("COMSTAR_LDAP_BIND_PASSWORD")
BASE_DN = _env("COMSTAR_LDAP_BASE_DN")
FACE_ATTR = _env("COMSTAR_LDAP_FACE_ATTR", "comstarFaceId")
VOICE_ATTR = _env("COMSTAR_LDAP_VOICE_ATTR", "comstarVoiceId")
HOST = _env("COMSTAR_DIR_HOST", "127.0.0.1")
PORT = int(_env("COMSTAR_DIR_PORT", "8780") or "8780")


def _escape_filter(value: str) -> str:
    """RFC 4515 filter escaping."""
    out: list[str] = []
    for ch in value:
        code = ord(ch)
        if ch in {"\\", "*", "(", ")"} or code == 0:
            out.append(f"\\{code:02x}")
        else:
            out.append(ch)
    return "".join(out)


def _first(attrs: dict[str, Any], *keys: str) -> str | None:
    for key in keys:
        raw = attrs.get(key)
        if raw is None:
            continue
        if isinstance(raw, (list, tuple)):
            if not raw:
                continue
            return str(raw[0])
        text = str(raw).strip()
        if text:
            return text
    return None


def _groups(attrs: dict[str, Any]) -> list[str]:
    raw = attrs.get("memberOf") or attrs.get("memberof") or []
    if not isinstance(raw, (list, tuple)):
        raw = [raw]
    names: list[str] = []
    for dn in raw:
        text = str(dn)
        # cn=comstar-users,cn=groups,... → comstar-users
        if text.lower().startswith("cn="):
            names.append(text.split(",", 1)[0][3:])
        else:
            names.append(text)
    return names


def ldap_configured() -> bool:
    return bool(LDAP_URL and BIND_DN and BASE_DN)


def resolve(attr: str, value: str) -> dict[str, Any] | None:
    """Return profile dict or None if not found. Raises on LDAP failure."""
    if not ldap_configured():
        raise RuntimeError("ldap_not_configured")
    if not value.strip():
        return None

    server = Server(LDAP_URL, get_info=ALL)
    conn = Connection(
        server,
        user=BIND_DN,
        password=BIND_PASSWORD,
        auto_bind=True,
        raise_exceptions=True,
    )
    try:
        filt = f"(&(objectClass=comstarPerson)({attr}={_escape_filter(value)}))"
        conn.search(
            BASE_DN,
            filt,
            attributes=[
                "uid",
                "cn",
                "displayName",
                "memberOf",
                FACE_ATTR,
                VOICE_ATTR,
            ],
        )
        if not conn.entries:
            # Fallback: uid == modality id (pre-comstarPerson migration).
            filt2 = f"(uid={_escape_filter(value)})"
            conn.search(
                BASE_DN,
                filt2,
                attributes=[
                    "uid",
                    "cn",
                    "displayName",
                    "memberOf",
                    FACE_ATTR,
                    VOICE_ATTR,
                ],
            )
        if not conn.entries:
            return None
        entry = conn.entries[0]
        attrs = entry.entry_attributes_as_dict
        uid = _first(attrs, "uid")
        if not uid:
            return None
        display = _first(attrs, "displayName", "cn") or uid
        profile: dict[str, Any] = {
            "uid": uid,
            "displayName": display,
            "groups": _groups(attrs),
            "dn": str(entry.entry_dn),
        }
        face = _first(attrs, FACE_ATTR)
        voice = _first(attrs, VOICE_ATTR)
        if face:
            profile["faceId"] = face
        if voice:
            profile["voiceId"] = voice
        return profile
    finally:
        conn.unbind()


def ldap_up() -> bool:
    if not ldap_configured():
        return False
    try:
        server = Server(LDAP_URL, get_info=ALL)
        conn = Connection(
            server,
            user=BIND_DN,
            password=BIND_PASSWORD,
            auto_bind=True,
            raise_exceptions=True,
        )
        conn.unbind()
        return True
    except Exception:  # noqa: BLE001
        return False


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write(f"[directory_sidecar] {self.address_string()} {fmt % args}\n")

    def _send(self, code: int, body: dict[str, Any]) -> None:
        raw = json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path in ("/health", "/"):
            self._send(200, {"ok": True, "ldap": "up" if ldap_up() else "down"})
            return
        if parsed.path != "/v1/resolve":
            self._send(404, {"error": "not_found"})
            return

        qs = parse_qs(parsed.query)
        face_id = (qs.get("face_id") or [None])[0]
        voice_id = (qs.get("voice_id") or [None])[0]
        if face_id and voice_id:
            self._send(400, {"error": "provide_face_id_or_voice_id"})
            return
        if not face_id and not voice_id:
            self._send(400, {"error": "missing_face_id_or_voice_id"})
            return

        attr = FACE_ATTR if face_id else VOICE_ATTR
        value = face_id or voice_id or ""
        try:
            profile = resolve(attr, value)
        except LDAPException as exc:
            self._send(503, {"error": "ldap_unavailable", "detail": str(exc)})
            return
        except RuntimeError as exc:
            self._send(503, {"error": str(exc)})
            return
        except Exception as exc:  # noqa: BLE001
            self._send(503, {"error": "ldap_unavailable", "detail": str(exc)})
            return

        if profile is None:
            self._send(404, {"error": "not_found"})
            return
        self._send(200, profile)


def main() -> None:
    if not ldap_configured():
        print(
            "warning: COMSTAR_LDAP_* not fully set; /v1/resolve will return 503",
            file=sys.stderr,
        )
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"directory_sidecar listening on http://{HOST}:{PORT}", file=sys.stderr)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
