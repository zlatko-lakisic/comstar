#!/usr/bin/env python3
"""COMSTAR vision MCP — CONTRACTS §5 tools wrapping CodeProject.AI + Frigate.

Runs on the AI server (or anywhere with CPAI + a frame source). Tools:

  who_is_present       → face recognize → {people, count}
  describe_view        → object detection → {objects}
  check_camera         → {ok, lastFrameAgeMs}
  list_person_visits   → Frigate person events → {visits, count}
  describe_visit       → named skip / else HA llmvision or OpenAI/Ollama
  who_visited          → voice summary (recognized + unknown descriptions)
  person_last_seen     → latest Frigate match for a name across cameras

Frame source (first match) for live tools:
  1. COMSTAR_VISION_FRAME_URL  — HTTP GET (e.g. Frigate latest.jpg)
  2. COMSTAR_VISION_FRAME      — local JPEG/PNG path
  3. args.image_b64            — optional override for tests
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo

CPAI_URL = os.environ.get("COMSTAR_CPAI_URL", "http://10.0.10.16:32168").rstrip("/")
DETECT_PATH = os.environ.get("COMSTAR_CPAI_DETECT", "/v1/vision/detection")
RECOGNIZE_PATH = os.environ.get("COMSTAR_CPAI_RECOGNIZE", "/v1/vision/face/recognize")
FRAME_URL = os.environ.get("COMSTAR_VISION_FRAME_URL", "").strip()
FRAME_PATH = os.environ.get("COMSTAR_VISION_FRAME", "").strip()
MIN_FACE = float(os.environ.get("COMSTAR_FACE_CONFIDENCE", "0.55"))
MIN_OBJ = float(os.environ.get("COMSTAR_DETECT_CONFIDENCE", "0.4"))

FRIGATE_URL = os.environ.get("COMSTAR_FRIGATE_URL", "http://127.0.0.1:5000").rstrip("/")
HA_URL = (
    os.environ.get("HOME_ASSISTANT_URL")
    or os.environ.get("COMSTAR_HA_URL")
    or ""
).rstrip("/")
HA_TOKEN = (
    os.environ.get("HOME_ASSISTANT_TOKEN")
    or os.environ.get("COMSTAR_HA_TOKEN")
    or ""
).strip()
OPENAI_API_KEY = (
    os.environ.get("OPENAI_API_KEY") or os.environ.get("COMSTAR_OPENAI_API_KEY") or ""
).strip()
OPENAI_BASE = (
    os.environ.get("OPENAI_BASE_URL")
    or os.environ.get("COMSTAR_OPENAI_BASE_URL")
    or "https://api.openai.com/v1"
).rstrip("/")
OLLAMA_URL = os.environ.get("COMSTAR_OLLAMA_URL", "http://127.0.0.1:11434").rstrip("/")
OLLAMA_VISION_MODEL = os.environ.get("COMSTAR_OLLAMA_VISION_MODEL", "moondream").strip()
LLMVISION_MODEL = os.environ.get("COMSTAR_LLMVISION_MODEL", "gpt-4o-mini").strip()
LLMVISION_PROVIDER = os.environ.get("COMSTAR_LLMVISION_PROVIDER", "").strip()
VISIT_TZ = os.environ.get("COMSTAR_TZ", "America/New_York").strip() or "America/New_York"
DEFAULT_CAMERA = os.environ.get("COMSTAR_VISIT_CAMERA", "driveway").strip() or "driveway"
MAX_UNKNOWN_DESCRIBE = int(os.environ.get("COMSTAR_VISIT_MAX_UNKNOWN", "5") or "5")
NAME_DEDUPE_SECONDS = int(os.environ.get("COMSTAR_VISIT_NAME_DEDUPE_SEC", "180") or "180")
LAST_SEEN_SINCE = os.environ.get("COMSTAR_LAST_SEEN_SINCE", "30d").strip() or "30d"

_LAST_FRAME_TS: float | None = None

_DESCRIBE_PROMPT = (
    "Describe the person in this security-camera snapshot for a short spoken "
    "summary. One or two sentences: clothing, approximate age/build if clear, "
    "and what they appear to be doing. Do not invent a name. If no person is "
    "visible, say so plainly."
)

TOOLS: list[dict[str, Any]] = [
    {
        "name": "who_is_present",
        "description": "Recognize known faces in the current camera frame via CPAI.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "describe_view",
        "description": "Object detection on the current camera frame via CPAI.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "check_camera",
        "description": "Report whether a fresh camera frame is available.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "list_person_visits",
        "description": (
            "List Frigate person events for a camera over a time range "
            "(default camera=driveway, since=today local midnight)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "camera": {"type": "string"},
                "since": {
                    "type": "string",
                    "description": "ISO timestamp, epoch seconds, or 'today'.",
                },
                "until": {"type": "string"},
                "limit": {"type": "integer"},
            },
        },
    },
    {
        "name": "describe_visit",
        "description": (
            "Describe one Frigate person event. Uses the recognized name when "
            "present; otherwise HA LLM Vision / OpenAI / local Ollama on the snapshot."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {"event_id": {"type": "string"}},
            "required": ["event_id"],
        },
    },
    {
        "name": "who_visited",
        "description": (
            "Voice-oriented summary of who was on a camera (default driveway) "
            "since a time (default today): recognized names plus descriptions "
            "of unrecognized people."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "camera": {"type": "string"},
                "since": {"type": "string"},
                "max_unknown": {"type": "integer"},
            },
        },
    },
    {
        "name": "person_last_seen",
        "description": (
            "When a named person was last recognized by Frigate face labels. "
            "Searches all cameras unless camera is set. Do not invent matches — "
            "only return Frigate sub_label hits for the queried name."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Person name or first name (e.g. Adna).",
                },
                "since": {
                    "type": "string",
                    "description": "Lookback window (default 30d).",
                },
                "camera": {
                    "type": "string",
                    "description": "Optional single camera; omit for all cameras.",
                },
                "limit": {"type": "integer"},
            },
            "required": ["name"],
        },
    },
]


def _ok(result: dict[str, Any]) -> dict[str, Any]:
    return {"ok": True, **result}


def _err(msg: str) -> dict[str, Any]:
    return {"ok": False, "error": msg}


def _http_json(
    url: str,
    *,
    method: str = "GET",
    data: bytes | None = None,
    headers: dict[str, str] | None = None,
    timeout: float = 30,
) -> Any:
    hdrs = dict(headers or {})
    req = Request(url, data=data, method=method, headers=hdrs)
    try:
        with urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            if not raw:
                return None
            return json.loads(raw.decode("utf-8"))
    except HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        try:
            return json.loads(body)
        except json.JSONDecodeError:
            raise RuntimeError(f"http_{e.code}:{body[:200]}") from e
    except (URLError, TimeoutError, json.JSONDecodeError) as e:
        raise RuntimeError(str(e)) from e


def _http_bytes(
    url: str,
    *,
    headers: dict[str, str] | None = None,
    timeout: float = 20,
) -> bytes:
    req = Request(url, method="GET", headers=headers or {})
    with urlopen(req, timeout=timeout) as resp:
        return resp.read()


def _load_frame(args: dict[str, Any]) -> tuple[bytes | None, str | None]:
    """Return (jpeg_bytes, error)."""
    global _LAST_FRAME_TS
    b64 = args.get("image_b64") if isinstance(args, dict) else None
    if isinstance(b64, str) and b64.strip():
        try:
            data = base64.b64decode(b64)
            _LAST_FRAME_TS = time.time()
            return data, None
        except Exception as e:  # noqa: BLE001
            return None, f"bad_image_b64:{e}"

    if FRAME_URL:
        try:
            req = Request(FRAME_URL, method="GET")
            with urlopen(req, timeout=5) as resp:
                data = resp.read()
            if not data:
                return None, "empty_frame_url"
            _LAST_FRAME_TS = time.time()
            return data, None
        except Exception as e:  # noqa: BLE001
            return None, f"frame_url:{e}"

    if FRAME_PATH:
        try:
            with open(FRAME_PATH, "rb") as f:
                data = f.read()
            if not data:
                return None, "empty_frame_path"
            _LAST_FRAME_TS = os.path.getmtime(FRAME_PATH)
            return data, None
        except Exception as e:  # noqa: BLE001
            return None, f"frame_path:{e}"

    return None, "no_frame_source (set COMSTAR_VISION_FRAME_URL or COMSTAR_VISION_FRAME)"


def _cpai_multipart(path: str, image: bytes, fields: dict[str, str]) -> dict[str, Any]:
    boundary = f"----comstar{uuid.uuid4().hex}"
    parts: list[bytes] = []
    for k, v in fields.items():
        parts.append(
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode()
        )
    parts.append(
        (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="image"; filename="frame.jpg"\r\n'
            f"Content-Type: image/jpeg\r\n\r\n"
        ).encode()
        + image
        + b"\r\n"
    )
    parts.append(f"--{boundary}--\r\n".encode())
    body = b"".join(parts)
    req = Request(
        f"{CPAI_URL}{path}",
        data=body,
        method="POST",
        headers={
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Content-Length": str(len(body)),
        },
    )
    try:
        with urlopen(req, timeout=8) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except HTTPError as e:
        try:
            return json.loads(e.read().decode("utf-8"))
        except Exception:
            return {"success": False, "error": f"http_{e.code}"}
    except (URLError, TimeoutError, json.JSONDecodeError) as e:
        return {"success": False, "error": str(e)}


def _tz() -> ZoneInfo:
    try:
        return ZoneInfo(VISIT_TZ)
    except Exception:
        return ZoneInfo("America/New_York")


def _parse_since(value: Any) -> float:
    """Return unix epoch seconds for since bound."""
    now = datetime.now(tz=_tz())
    if value is None or (isinstance(value, str) and not value.strip()):
        value = "today"
    if isinstance(value, (int, float)):
        return float(value)
    s = str(value).strip().lower()
    if s in ("today", "today_local", "start_of_day"):
        start = now.replace(hour=0, minute=0, second=0, microsecond=0)
        return start.timestamp()
    if s in ("yesterday",):
        start = (now - timedelta(days=1)).replace(
            hour=0, minute=0, second=0, microsecond=0
        )
        return start.timestamp()
    if s.endswith("d") and s[:-1].replace(".", "", 1).isdigit():
        days = float(s[:-1])
        return (now - timedelta(days=days)).timestamp()
    if s.endswith("h") and s[:-1].replace(".", "", 1).isdigit():
        hours = float(s[:-1])
        return (now - timedelta(hours=hours)).timestamp()
    if s.isdigit():
        return float(s)
    # ISO-ish
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=_tz())
        return dt.timestamp()
    except ValueError as e:
        raise ValueError(f"bad_since:{value}") from e


def _parse_until(value: Any) -> float | None:
    if value is None or (isinstance(value, str) and not value.strip()):
        return None
    return _parse_since(value)


def _fmt_local(ts: float) -> str:
    text = datetime.fromtimestamp(ts, tz=_tz()).strftime("%I:%M %p")
    return text.lstrip("0") if text.startswith("0") else text


def _fmt_day_when(ts: float) -> str:
    """Relative day + local time for spoken answers."""
    local = datetime.fromtimestamp(ts, tz=_tz())
    now = datetime.now(tz=_tz())
    today = now.date()
    d = local.date()
    clock = _fmt_local(ts)
    if d == today:
        return f"today at {clock}"
    if d == today - timedelta(days=1):
        return f"yesterday at {clock}"
    return f"{local.strftime('%B')} {local.day} at {clock}"


def _speak_camera(camera: str) -> str:
    return (camera or "camera").replace("_", " ").strip()


def _edit_distance(a: str, b: str) -> int:
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, start=1):
        cur = [i]
        for j, cb in enumerate(b, start=1):
            ins = cur[j - 1] + 1
            delete = prev[j] + 1
            sub = prev[j - 1] + (0 if ca == cb else 1)
            cur.append(min(ins, delete, sub))
        prev = cur
    return prev[-1]


def _name_matches(query: str, full_name: str) -> bool:
    """Match Frigate sub_label to a spoken first/full name (no inventing)."""
    q = " ".join(query.strip().lower().split())
    n = " ".join(full_name.strip().lower().split())
    if not q or not n or len(q) < 2:
        return False
    if q == n:
        return True
    tokens = n.split()
    if q in tokens:
        return True
    if n.startswith(q + " "):
        return True
    # Soft first-name match (STT Adna/Anna) — only for short names ≥3 chars.
    first = tokens[0] if tokens else ""
    if len(q) >= 3 and first and _edit_distance(q, first) <= 1:
        return True
    return False


def _event_name(ev: dict[str, Any]) -> str | None:
    sub = ev.get("sub_label")
    if isinstance(sub, list) and sub:
        sub = sub[0]
    if sub is None:
        return None
    name = str(sub).strip()
    if not name or name.lower() in ("unknown", "none", "null"):
        return None
    return name


def _event_score(ev: dict[str, Any]) -> float | None:
    data = ev.get("data") if isinstance(ev.get("data"), dict) else {}
    for key in ("top_score", "score"):
        if data.get(key) is not None:
            try:
                return float(data[key])
            except (TypeError, ValueError):
                pass
        if ev.get(key) is not None:
            try:
                return float(ev[key])
            except (TypeError, ValueError):
                pass
    return None


def _normalize_visit(ev: dict[str, Any]) -> dict[str, Any]:
    start = float(ev.get("start_time") or 0)
    end = ev.get("end_time")
    return {
        "id": str(ev.get("id") or ""),
        "start": start,
        "end": float(end) if end is not None else None,
        "when": _fmt_local(start) if start else None,
        "camera": str(ev.get("camera") or ""),
        "label": str(ev.get("label") or "person"),
        "name": _event_name(ev),
        "score": _event_score(ev),
        "has_snapshot": bool(ev.get("has_snapshot")),
    }


def _frigate_events(
    *,
    camera: str | None,
    after: float,
    before: float | None,
    limit: int,
) -> list[dict[str, Any]]:
    params: dict[str, str] = {
        "label": "person",
        "after": str(after),
        "limit": str(max(1, min(limit, 500))),
        "has_snapshot": "1",
    }
    if camera:
        params["camera"] = camera
    if before is not None:
        params["before"] = str(before)
    url = f"{FRIGATE_URL}/api/events?{urlencode(params)}"
    raw = _http_json(url, timeout=20)
    if not isinstance(raw, list):
        raise RuntimeError(f"frigate_events_bad_response:{type(raw).__name__}")
    return [e for e in raw if isinstance(e, dict)]


def _frigate_event(event_id: str) -> dict[str, Any]:
    raw = _http_json(f"{FRIGATE_URL}/api/events/{event_id}", timeout=15)
    if not isinstance(raw, dict):
        raise RuntimeError("frigate_event_not_found")
    return raw


def _frigate_snapshot(event_id: str) -> bytes:
    return _http_bytes(
        f"{FRIGATE_URL}/api/events/{event_id}/snapshot.jpg",
        timeout=20,
    )


def _ha_headers() -> dict[str, str]:
    return {
        "Authorization": f"Bearer {HA_TOKEN}",
        "Content-Type": "application/json",
    }


def _ha_llmvision_describe(event_id: str, jpeg: bytes) -> str:
    """Call HA llmvision.image_analyzer (same stack as driveway notifications)."""
    if not HA_URL or not HA_TOKEN:
        raise RuntimeError("ha_not_configured")

    # Prefer HA Frigate notification proxy (HA already has the event media).
    snap_paths = [
        f"/api/frigate/notifications/{event_id}/snapshot.jpg",
        f"/api/frigate/notifications/{event_id}/snapshot.jpeg",
    ]
    image_file: str | None = None
    for path in snap_paths:
        try:
            probe = _http_bytes(
                f"{HA_URL}{path}",
                headers={"Authorization": f"Bearer {HA_TOKEN}"},
                timeout=15,
            )
            if probe and len(probe) > 100:
                # llmvision can often fetch HA-relative media when given a
                # www/tmp file; stage via /local if proxy path alone fails.
                image_file = f"{HA_URL}{path}"
                break
        except Exception:
            continue

    if image_file is None:
        # Stage under /config/www via HA downloader is unavailable; fall through
        # with data-URI attempt (supported by some llmvision builds).
        b64 = base64.b64encode(jpeg).decode("ascii")
        image_file = f"data:image/jpeg;base64,{b64}"

    payload: dict[str, Any] = {
        "model": LLMVISION_MODEL,
        "message": _DESCRIBE_PROMPT,
        "max_tokens": 160,
        "temperature": 0.1,
        "generate_title": False,
        "include_filename": False,
        "target_width": 640,
        "image_file": image_file,
    }
    if LLMVISION_PROVIDER:
        payload["provider"] = LLMVISION_PROVIDER

    url = f"{HA_URL}/api/services/llmvision/image_analyzer?return_response"
    raw = _http_json(
        url,
        method="POST",
        data=json.dumps(payload).encode("utf-8"),
        headers=_ha_headers(),
        timeout=90,
    )
    text = _extract_llmvision_text(raw)
    if not text:
        raise RuntimeError(f"ha_llmvision_empty:{raw!r}"[:240])
    return text


def _extract_llmvision_text(raw: Any) -> str:
    if raw is None:
        return ""
    if isinstance(raw, str):
        return raw.strip()
    if isinstance(raw, list) and raw:
        return _extract_llmvision_text(raw[0])
    if not isinstance(raw, dict):
        return ""
    for key in ("response_text", "response", "text", "result"):
        val = raw.get(key)
        if isinstance(val, str) and val.strip():
            return val.strip()
        if isinstance(val, dict):
            nested = _extract_llmvision_text(val)
            if nested:
                return nested
    # service response shape: {service_response: {...}} or {response: {response_text}}
    for key in ("service_response", "data", "attributes"):
        if key in raw:
            nested = _extract_llmvision_text(raw[key])
            if nested:
                return nested
    return ""


def _openai_describe(jpeg: bytes) -> str:
    if not OPENAI_API_KEY:
        raise RuntimeError("openai_not_configured")
    b64 = base64.b64encode(jpeg).decode("ascii")
    body = {
        "model": LLMVISION_MODEL,
        "temperature": 0.1,
        "max_tokens": 160,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": _DESCRIBE_PROMPT},
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:image/jpeg;base64,{b64}"},
                    },
                ],
            }
        ],
    }
    raw = _http_json(
        f"{OPENAI_BASE}/chat/completions",
        method="POST",
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {OPENAI_API_KEY}",
            "Content-Type": "application/json",
        },
        timeout=90,
    )
    if not isinstance(raw, dict):
        raise RuntimeError("openai_bad_response")
    choices = raw.get("choices") or []
    if not choices:
        raise RuntimeError("openai_no_choices")
    msg = (choices[0] or {}).get("message") or {}
    content = msg.get("content")
    if isinstance(content, list):
        parts = []
        for p in content:
            if isinstance(p, dict) and p.get("type") == "text":
                parts.append(str(p.get("text") or ""))
        content = " ".join(parts)
    text = str(content or "").strip()
    if not text:
        raise RuntimeError("openai_empty")
    return text


def _ollama_describe(jpeg: bytes) -> str:
    b64 = base64.b64encode(jpeg).decode("ascii")
    body = {
        "model": OLLAMA_VISION_MODEL,
        "prompt": _DESCRIBE_PROMPT,
        "images": [b64],
        "stream": False,
    }
    raw = _http_json(
        f"{OLLAMA_URL}/api/generate",
        method="POST",
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        timeout=120,
    )
    if not isinstance(raw, dict):
        raise RuntimeError("ollama_bad_response")
    text = str(raw.get("response") or "").strip()
    if not text:
        raise RuntimeError("ollama_empty")
    return text


def _describe_unknown(event_id: str, jpeg: bytes) -> tuple[str, str]:
    """Return (description, backend). Prefer HA llmvision, then OpenAI, then Ollama."""
    errors: list[str] = []
    if HA_URL and HA_TOKEN:
        try:
            return _ha_llmvision_describe(event_id, jpeg), "ha_llmvision"
        except Exception as e:  # noqa: BLE001
            errors.append(f"ha:{e}")
    if OPENAI_API_KEY:
        try:
            return _openai_describe(jpeg), "openai"
        except Exception as e:  # noqa: BLE001
            errors.append(f"openai:{e}")
    try:
        return _ollama_describe(jpeg), "ollama"
    except Exception as e:  # noqa: BLE001
        errors.append(f"ollama:{e}")
    raise RuntimeError("; ".join(errors) or "describe_failed")


def _list_visits(args: dict[str, Any]) -> dict[str, Any]:
    camera = str(args.get("camera") or DEFAULT_CAMERA).strip() or DEFAULT_CAMERA
    try:
        after = _parse_since(args.get("since"))
        before = _parse_until(args.get("until"))
    except ValueError as e:
        return _err(str(e))
    limit = int(args.get("limit") or 100)
    try:
        events = _frigate_events(
            camera=camera, after=after, before=before, limit=limit
        )
    except Exception as e:  # noqa: BLE001
        return _err(f"frigate:{e}")
    visits = [_normalize_visit(e) for e in events if e.get("id")]
    visits.sort(key=lambda v: v.get("start") or 0)
    return _ok(
        {
            "camera": camera,
            "since": after,
            "until": before,
            "visits": visits,
            "count": len(visits),
        }
    )


def _describe_visit(args: dict[str, Any]) -> dict[str, Any]:
    event_id = str(args.get("event_id") or "").strip()
    if not event_id:
        return _err("missing_event_id")
    try:
        ev = _frigate_event(event_id)
    except Exception as e:  # noqa: BLE001
        return _err(f"frigate:{e}")
    name = _event_name(ev)
    visit = _normalize_visit(ev)
    if name:
        return _ok(
            {
                "event_id": event_id,
                "name": name,
                "description": f"{name} was seen on the {visit.get('camera')} camera.",
                "when": visit.get("when"),
                "recognized": True,
            }
        )
    if not ev.get("has_snapshot"):
        return _ok(
            {
                "event_id": event_id,
                "name": None,
                "description": "An unrecognized person was detected, but no snapshot is available.",
                "when": visit.get("when"),
                "recognized": False,
            }
        )
    try:
        jpeg = _frigate_snapshot(event_id)
        description, backend = _describe_unknown(event_id, jpeg)
    except Exception as e:  # noqa: BLE001
        return _err(f"describe:{e}")
    return _ok(
        {
            "event_id": event_id,
            "name": None,
            "description": description,
            "when": visit.get("when"),
            "recognized": False,
            "backend": backend,
        }
    )


def _dedupe_named(
    visits: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Collapse near-duplicate named sightings."""
    out: list[dict[str, Any]] = []
    last_by_name: dict[str, float] = {}
    for v in visits:
        name = v.get("name")
        start = float(v.get("start") or 0)
        if name:
            key = name.lower()
            prev = last_by_name.get(key)
            if prev is not None and abs(start - prev) < NAME_DEDUPE_SECONDS:
                continue
            last_by_name[key] = start
        out.append(v)
    return out


def _who_visited(args: dict[str, Any]) -> dict[str, Any]:
    listed = _list_visits(
        {
            "camera": args.get("camera") or DEFAULT_CAMERA,
            "since": args.get("since") or "today",
            "limit": args.get("limit") or 80,
        }
    )
    if not listed.get("ok"):
        return listed
    visits = _dedupe_named(list(listed.get("visits") or []))
    recognized_map: dict[str, list[str]] = {}
    unknown_raw: list[dict[str, Any]] = []
    for v in visits:
        name = v.get("name")
        when = v.get("when") or ""
        if name:
            recognized_map.setdefault(name, []).append(when)
        elif v.get("has_snapshot"):
            unknown_raw.append(v)

    recognized = [
        {"name": n, "times": times, "count": len(times)}
        for n, times in recognized_map.items()
    ]
    try:
        max_unknown = int(args.get("max_unknown") or MAX_UNKNOWN_DESCRIBE)
    except (TypeError, ValueError):
        max_unknown = MAX_UNKNOWN_DESCRIBE
    max_unknown = max(0, min(max_unknown, MAX_UNKNOWN_DESCRIBE))

    unknown: list[dict[str, Any]] = []
    for v in unknown_raw[:max_unknown]:
        desc_res = _describe_visit({"event_id": v.get("id")})
        if desc_res.get("ok"):
            unknown.append(
                {
                    "when": desc_res.get("when") or v.get("when"),
                    "description": desc_res.get("description"),
                    "event_id": v.get("id"),
                    "backend": desc_res.get("backend"),
                }
            )
        else:
            unknown.append(
                {
                    "when": v.get("when"),
                    "description": "An unrecognized person was seen (description unavailable).",
                    "event_id": v.get("id"),
                    "error": desc_res.get("error"),
                }
            )

    skipped_unknown = max(0, len(unknown_raw) - len(unknown))
    camera = listed.get("camera")
    parts: list[str] = []
    if not recognized and not unknown and not unknown_raw:
        spoken = f"I did not see any people on the {camera} camera in that period."
    else:
        if recognized:
            bits = []
            for r in recognized:
                times = ", ".join(t for t in r["times"] if t) or "earlier"
                bits.append(f"{r['name']} ({times})")
            parts.append("Recognized: " + "; ".join(bits) + ".")
        if unknown:
            bits = []
            for u in unknown:
                when = u.get("when") or "sometime"
                bits.append(f"Around {when}: {u.get('description')}")
            parts.append("Unrecognized: " + " ".join(bits))
        if skipped_unknown:
            parts.append(
                f"Plus {skipped_unknown} more unrecognized visit"
                f"{'' if skipped_unknown == 1 else 's'} I did not describe."
            )
        spoken = " ".join(parts)

    return _ok(
        {
            "camera": camera,
            "since": listed.get("since"),
            "recognized": recognized,
            "unknown": unknown,
            "unknown_total": len(unknown_raw),
            "unknown_described": len(unknown),
            "visit_count": len(visits),
            "spoken_hint": spoken,
        }
    )


def _person_last_seen(args: dict[str, Any]) -> dict[str, Any]:
    query = str(args.get("name") or "").strip()
    if not query:
        return _err("missing_name")
    camera_raw = args.get("camera")
    camera = str(camera_raw).strip() if camera_raw else None
    if camera == "":
        camera = None
    try:
        after = _parse_since(args.get("since") or LAST_SEEN_SINCE)
    except ValueError as e:
        return _err(str(e))
    limit = int(args.get("limit") or 300)
    try:
        events = _frigate_events(
            camera=camera, after=after, before=None, limit=limit
        )
    except Exception as e:  # noqa: BLE001
        return _err(f"frigate:{e}")

    matches: list[dict[str, Any]] = []
    for ev in events:
        name = _event_name(ev)
        if not name or not _name_matches(query, name):
            continue
        visit = _normalize_visit(ev)
        visit["matched_name"] = name
        matches.append(visit)
    matches.sort(key=lambda v: v.get("start") or 0, reverse=True)

    if not matches:
        window = str(args.get("since") or LAST_SEEN_SINCE)
        cam_bit = f" on the {_speak_camera(camera)} camera" if camera else ""
        spoken = (
            f"I have not seen anyone Frigate recognizes as {query}"
            f"{cam_bit} in the last {window}."
        )
        return _ok(
            {
                "query": query,
                "matched_name": None,
                "found": False,
                "last": None,
                "recent": [],
                "count": 0,
                "spoken_hint": spoken,
            }
        )

    last = matches[0]
    matched_name = str(last.get("matched_name") or query)
    when = _fmt_day_when(float(last.get("start") or 0))
    cam = _speak_camera(str(last.get("camera") or ""))
    spoken = f"{matched_name} was last seen {when} on the {cam} camera."
    # Mention a second distinct camera/time only if useful.
    if len(matches) > 1:
        prev = matches[1]
        if prev.get("camera") != last.get("camera"):
            spoken += (
                f" Before that, {_fmt_day_when(float(prev.get('start') or 0))}"
                f" on the {_speak_camera(str(prev.get('camera') or ''))} camera."
            )

    return _ok(
        {
            "query": query,
            "matched_name": matched_name,
            "found": True,
            "last": {
                "id": last.get("id"),
                "name": matched_name,
                "camera": last.get("camera"),
                "when": last.get("when"),
                "start": last.get("start"),
                "day_when": when,
            },
            "recent": [
                {
                    "id": v.get("id"),
                    "name": v.get("matched_name"),
                    "camera": v.get("camera"),
                    "when": v.get("when"),
                    "start": v.get("start"),
                }
                for v in matches[:5]
            ],
            "count": len(matches),
            "spoken_hint": spoken,
        }
    )


def handle_tool(name: str, args: dict[str, Any]) -> dict[str, Any]:
    if name == "check_camera":
        age_ms = None
        ok = False
        if _LAST_FRAME_TS is not None:
            age_ms = int((time.time() - _LAST_FRAME_TS) * 1000)
            ok = age_ms < 30_000
        elif FRAME_PATH and os.path.isfile(FRAME_PATH):
            age_ms = int((time.time() - os.path.getmtime(FRAME_PATH)) * 1000)
            ok = age_ms < 30_000
        elif FRAME_URL:
            try:
                with urlopen(Request(FRAME_URL, method="GET"), timeout=3) as resp:
                    ok = resp.status == 200 and len(resp.read()) > 0
                age_ms = 0 if ok else None
            except Exception:
                ok = False
        else:
            return _ok({"ok": False, "lastFrameAgeMs": None, "hint": "no_frame_source"})
        return _ok({"ok": ok, "lastFrameAgeMs": age_ms})

    if name in ("who_is_present", "describe_view"):
        image, err = _load_frame(args)
        if image is None:
            return _err(err or "no_frame")

        if name == "who_is_present":
            raw = _cpai_multipart(
                RECOGNIZE_PATH,
                image,
                {"min_confidence": str(MIN_FACE)},
            )
            if not raw.get("success"):
                return _err(raw.get("error") or raw.get("message") or "recognize_failed")
            people = []
            for p in raw.get("predictions") or []:
                if not isinstance(p, dict):
                    continue
                userid = str(p.get("userid") or "")
                conf = float(p.get("confidence") or 0)
                if not userid or userid.lower() == "unknown":
                    continue
                if conf < MIN_FACE:
                    continue
                people.append({"userid": userid, "confidence": conf})
            return _ok({"people": people, "count": len(people)})

        raw = _cpai_multipart(
            DETECT_PATH,
            image,
            {"min_confidence": str(MIN_OBJ)},
        )
        if not raw.get("success"):
            return _err(raw.get("error") or raw.get("message") or "detect_failed")
        objects = []
        for p in raw.get("predictions") or []:
            if not isinstance(p, dict):
                continue
            label = str(p.get("label") or "")
            conf = float(p.get("confidence") or 0)
            if not label or conf < MIN_OBJ:
                continue
            objects.append({"label": label, "confidence": conf})
        return _ok({"objects": objects})

    if name == "list_person_visits":
        return _list_visits(args)
    if name == "describe_visit":
        return _describe_visit(args)
    if name == "who_visited":
        return _who_visited(args)
    if name == "person_last_seen":
        return _person_last_seen(args)

    return _err(f"unknown tool: {name}")


def dispatch_rpc(req: dict[str, Any]) -> dict[str, Any] | None:
    method = req.get("method")
    req_id = req.get("id")
    params = req.get("params") or {}

    if req_id is None and isinstance(method, str) and method.startswith("notifications/"):
        return None

    if method == "initialize":
        result: Any = {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "comstar-vision", "version": "0.2.0"},
        }
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        name = params.get("name", "") if isinstance(params, dict) else ""
        args = params.get("arguments") or {} if isinstance(params, dict) else {}
        payload = handle_tool(name, args if isinstance(args, dict) else {})
        result = {
            "content": [{"type": "text", "text": json.dumps(payload)}],
            "isError": not payload.get("ok", True) and "error" in payload,
        }
    elif method is None and "result" in req:
        return None
    else:
        if req_id is None:
            return None
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32601, "message": f"Method not found: {method}"},
        }

    if req_id is None:
        return None
    return {"jsonrpc": "2.0", "id": req_id, "result": result}


def main_stdio() -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(req, dict):
            continue
        resp = dispatch_rpc(req)
        if resp is not None:
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()


class _McpHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A003
        sys.stderr.write("[vision_mcp] " + (format % args) + "\n")

    def _cors(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        if self.path.split("?", 1)[0] not in ("/mcp", "/", "/health"):
            self.send_error(404)
            return
        if self.path.split("?", 1)[0] == "/health":
            body = json.dumps(
                {
                    "ok": True,
                    "service": "comstar-vision",
                    "frigate": bool(FRIGATE_URL),
                    "ha": bool(HA_URL and HA_TOKEN),
                    "openai": bool(OPENAI_API_KEY),
                }
            ).encode()
            self.send_response(200)
            self._cors()
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(405)
        self._cors()
        self.send_header("Allow", "POST, OPTIONS")
        self.end_headers()

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path not in ("/mcp", "/"):
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length > 0 else b"{}"
        try:
            req = json.loads(raw.decode("utf-8") or "{}")
        except json.JSONDecodeError:
            self.send_response(400)
            self._cors()
            self.send_header("Content-Type", "application/json")
            body = json.dumps(
                {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}}
            ).encode()
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if not isinstance(req, dict):
            self.send_response(400)
            self._cors()
            self.end_headers()
            return

        resp = dispatch_rpc(req)
        if resp is None:
            self.send_response(202)
            self._cors()
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        body = json.dumps(resp).encode("utf-8")
        self.send_response(200)
        self._cors()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if req.get("method") == "initialize":
            self.send_header("Mcp-Session-Id", uuid.uuid4().hex)
        self.end_headers()
        self.wfile.write(body)


def main_http(host: str, port: int) -> None:
    httpd = ThreadingHTTPServer((host, port), _McpHandler)
    sys.stderr.write(f"vision_mcp_http_ready host={host} port={httpd.server_address[1]}\n")
    sys.stderr.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


def main() -> None:
    parser = argparse.ArgumentParser(description="COMSTAR vision MCP")
    parser.add_argument("--http", action="store_true")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()

    use_http = args.http or os.environ.get("COMSTAR_MCP_HTTP", "").strip() in (
        "1",
        "true",
        "yes",
    )
    if use_http:
        port = args.port
        if port == 0:
            env_port = os.environ.get("COMSTAR_MCP_HTTP_PORT", "").strip()
            port = int(env_port) if env_port.isdigit() else 8793
        main_http(args.host, port)
    else:
        main_stdio()


if __name__ == "__main__":
    main()
