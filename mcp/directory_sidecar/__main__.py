"""COMSTAR directory sidecar — FreeIPA face/voice id → uid resolve (ADR 0005)."""

from __future__ import annotations

import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, urlparse

try:
    from ldap3 import ALL, Connection, Server
    from ldap3.core.exceptions import LDAPException
    from ldap3.utils.conv import escape_filter_chars
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
HA_PERSON_ATTR = _env("COMSTAR_LDAP_HA_PERSON_ATTR", "comstarHaPerson")
HOST = _env("COMSTAR_DIR_HOST", "127.0.0.1")
PORT = int(_env("COMSTAR_DIR_PORT", "8780") or "8780")

_ATTR_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_-]{0,63}$")
_MODALITY_ID = re.compile(r"^[A-Za-z0-9._:@+=/-]{1,128}$")
_UID = re.compile(r"^[A-Za-z0-9._-]{1,64}$")


def _escape_filter(value: str) -> str:
    """RFC 4515 filter escaping via ldap3 (CodeQL-recognized)."""
    return escape_filter_chars(value)


def _safe_attr(attr: str) -> str | None:
    if not _ATTR_NAME.match(attr):
        return None
    if attr not in {FACE_ATTR, VOICE_ATTR, HA_PERSON_ATTR, "uid"}:
        return None
    return attr


def _safe_modality_id(value: str) -> str | None:
    text = value.strip()
    if not text or not _MODALITY_ID.match(text):
        return None
    return text


def _safe_uid(value: str) -> str | None:
    text = value.strip()
    if not text or not _UID.match(text):
        return None
    return text


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
        if text.lower().startswith("cn="):
            names.append(text.split(",", 1)[0][3:])
        else:
            names.append(text)
    return names


def ldap_configured() -> bool:
    return bool(LDAP_URL and BIND_DN and BASE_DN)


_SEARCH_ATTRS = [
    "uid",
    "cn",
    "displayName",
    "memberOf",
    FACE_ATTR,
    VOICE_ATTR,
    HA_PERSON_ATTR,
]


def _profile_from_entry(entry: Any) -> dict[str, Any] | None:
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
    ha = _first(attrs, HA_PERSON_ATTR)
    if face:
        profile["faceId"] = face
    if voice:
        profile["voiceId"] = voice
    if ha:
        profile["haPerson"] = ha
    return profile


def resolve(attr: str, value: str) -> dict[str, Any] | None:
    """Return profile dict or None if not found. Raises on LDAP failure."""
    if not ldap_configured():
        raise RuntimeError("ldap_not_configured")
    safe_attr = _safe_attr(attr)
    safe_value = _safe_uid(value) if attr == "uid" else _safe_modality_id(value)
    if not safe_attr or not safe_value:
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
        escaped = _escape_filter(safe_value)
        filt = f"(&(objectClass=comstarPerson)({safe_attr}={escaped}))"
        conn.search(BASE_DN, filt, attributes=_SEARCH_ATTRS)
        if not conn.entries:
            filt2 = f"(uid={escaped})"
            conn.search(BASE_DN, filt2, attributes=_SEARCH_ATTRS)
        if not conn.entries:
            return None
        return _profile_from_entry(conn.entries[0])
    finally:
        conn.unbind()


def lookup_uid(uid: str) -> dict[str, Any] | None:
    return resolve("uid", uid)


def list_comstar_users(limit: int = 50) -> list[dict[str, Any]]:
    if not ldap_configured():
        raise RuntimeError("ldap_not_configured")
    limit = max(1, min(200, int(limit)))
    server = Server(LDAP_URL, get_info=ALL)
    conn = Connection(
        server,
        user=BIND_DN,
        password=BIND_PASSWORD,
        auto_bind=True,
        raise_exceptions=True,
    )
    try:
        conn.search(
            BASE_DN,
            "(objectClass=comstarPerson)",
            attributes=_SEARCH_ATTRS,
            size_limit=limit,
        )
        out: list[dict[str, Any]] = []
        for entry in conn.entries:
            profile = _profile_from_entry(entry)
            if profile:
                out.append(profile)
        return out
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

        qs = parse_qs(parsed.query)

        if parsed.path == "/v1/lookup":
            uid = (qs.get("uid") or [None])[0]
            if not uid:
                self._send(400, {"error": "missing_uid"})
                return
            try:
                profile = lookup_uid(uid)
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
            return

        if parsed.path == "/v1/users":
            try:
                limit = int((qs.get("limit") or ["50"])[0] or "50")
            except ValueError:
                limit = 50
            try:
                users = list_comstar_users(limit=limit)
            except LDAPException as exc:
                self._send(503, {"error": "ldap_unavailable", "detail": str(exc)})
                return
            except RuntimeError as exc:
                self._send(503, {"error": str(exc)})
                return
            except Exception as exc:  # noqa: BLE001
                self._send(503, {"error": "ldap_unavailable", "detail": str(exc)})
                return
            self._send(200, {"users": users, "count": len(users)})
            return

        if parsed.path != "/v1/resolve":
            self._send(404, {"error": "not_found"})
            return

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
