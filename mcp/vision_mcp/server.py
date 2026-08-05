#!/usr/bin/env python3
"""COMSTAR vision MCP — CONTRACTS §5 tools wrapping CodeProject.AI.

Runs on the AI server (or anywhere with CPAI + a frame source). Tools:

  who_is_present  → face recognize → {people, count}
  describe_view   → object detection → {objects}
  check_camera    → {ok, lastFrameAgeMs}

Frame source (first match):
  1. COMSTAR_VISION_FRAME_URL  — HTTP GET (e.g. Pi snapshot)
  2. COMSTAR_VISION_FRAME      — local JPEG/PNG path
  3. args.image_b64            — optional override for tests

Without a frame, who_is_present / describe_view return ok:false.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

CPAI_URL = os.environ.get("COMSTAR_CPAI_URL", "http://10.0.10.16:32168").rstrip("/")
DETECT_PATH = os.environ.get("COMSTAR_CPAI_DETECT", "/v1/vision/detection")
RECOGNIZE_PATH = os.environ.get("COMSTAR_CPAI_RECOGNIZE", "/v1/vision/face/recognize")
FRAME_URL = os.environ.get("COMSTAR_VISION_FRAME_URL", "").strip()
FRAME_PATH = os.environ.get("COMSTAR_VISION_FRAME", "").strip()
MIN_FACE = float(os.environ.get("COMSTAR_FACE_CONFIDENCE", "0.55"))
MIN_OBJ = float(os.environ.get("COMSTAR_DETECT_CONFIDENCE", "0.4"))

_LAST_FRAME_TS: float | None = None

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
]


def _ok(result: dict[str, Any]) -> dict[str, Any]:
    return {"ok": True, **result}


def _err(msg: str) -> dict[str, Any]:
    return {"ok": False, "error": msg}


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
            # Probe without caching as "last frame" for recognize.
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
            "serverInfo": {"name": "comstar-vision", "version": "0.1.0"},
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
            body = json.dumps({"ok": True, "service": "comstar-vision"}).encode()
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
