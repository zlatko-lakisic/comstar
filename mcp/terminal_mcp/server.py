#!/usr/bin/env python3
"""COMSTAR terminal MCP — CONTRACTS §5 tools.

Supports:
  - stdio NDJSON (local tests / optional mcp-proxy)
  - streamable HTTP on ``/mcp`` (preferred for AO tunnel; no Node required)

Sleep/volume call bridge loopback HTTP; display/tone/mic remain soft-state stubs.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

CONTROL_BASE = os.environ.get("COMSTAR_CONTROL_URL", "http://127.0.0.1:8776").rstrip(
    "/"
)

STATE: dict[str, Any] = {
    "display_mode": "avatar",
    "muted": False,
    "device_ok": True,
    "last_wake_ago_ms": None,
    "screen_on": True,
    "brightness": 1.0,
}


def _ok(result: dict[str, Any]) -> dict[str, Any]:
    return {"ok": True, **result}


def _http_json(method: str, path: str, body: dict[str, Any] | None = None) -> dict[str, Any]:
    url = f"{CONTROL_BASE}{path}"
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            raw = resp.read().decode("utf-8")
            if not raw.strip():
                return {"ok": True}
            return json.loads(raw)
    except urllib.error.HTTPError as e:
        try:
            payload = json.loads(e.read().decode("utf-8"))
            if isinstance(payload, dict):
                return payload
        except Exception:
            pass
        return {"ok": False, "error": f"http_{e.code}"}
    except Exception as e:  # noqa: BLE001 — surface to tool caller
        return {"ok": False, "error": str(e)}


def handle_tool(name: str, args: dict[str, Any]) -> dict[str, Any]:
    if name == "set_display":
        mode = args.get("mode", "avatar")
        if mode not in ("avatar", "clock", "blank"):
            return {"ok": False, "error": f"invalid mode: {mode}"}
        STATE["display_mode"] = mode
        return _ok({"mode": mode})
    if name == "play_tone":
        tone = args.get("tone", "ack")
        if tone not in ("ack", "error", "attention"):
            return {"ok": False, "error": f"invalid tone: {tone}"}
        return _ok({"tone": tone})
    if name == "mic_status":
        return {
            "muted": STATE["muted"],
            "deviceOk": STATE["device_ok"],
            "lastWakeAgoMs": STATE["last_wake_ago_ms"],
        }
    if name == "screen_state":
        return {"on": STATE["screen_on"], "brightness": STATE["brightness"]}
    if name == "sleep_enter":
        return _http_json("POST", "/control/sleep", {"action": "enter"})
    if name == "sleep_status":
        return _http_json("GET", "/control/sleep")
    if name == "volume_get":
        return _http_json("GET", "/control/volume")
    if name == "volume_set":
        percent = args.get("percent")
        if not isinstance(percent, (int, float)):
            return {"ok": False, "error": "percent_required"}
        return _http_json(
            "POST", "/control/volume", {"action": "set", "percent": int(percent)}
        )
    if name == "volume_adjust":
        delta = args.get("delta")
        if not isinstance(delta, (int, float)):
            return {"ok": False, "error": "delta_required"}
        return _http_json(
            "POST", "/control/volume", {"action": "adjust", "delta": int(delta)}
        )
    if name == "volume_mute":
        muted = args.get("muted")
        if not isinstance(muted, bool):
            return {"ok": False, "error": "muted_required"}
        return _http_json(
            "POST", "/control/volume", {"action": "mute", "muted": muted}
        )
    return {"ok": False, "error": f"unknown tool: {name}"}


TOOLS = [
    {
        "name": "set_display",
        "description": "Set kiosk display mode",
        "inputSchema": {
            "type": "object",
            "properties": {
                "mode": {"type": "string", "enum": ["avatar", "clock", "blank"]},
            },
            "required": ["mode"],
        },
    },
    {
        "name": "play_tone",
        "description": "Play a short UI tone",
        "inputSchema": {
            "type": "object",
            "properties": {
                "tone": {"type": "string", "enum": ["ack", "error", "attention"]},
            },
            "required": ["tone"],
        },
    },
    {
        "name": "mic_status",
        "description": "Microphone mute / health",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "screen_state",
        "description": "Panel power and brightness",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "sleep_enter",
        "description": "Put COMSTAR to sleep (ignore vision/speech until hey comstar)",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "sleep_status",
        "description": "Whether COMSTAR is sleeping",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "volume_get",
        "description": "Get HDMI/speaker volume and mute state",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "volume_set",
        "description": "Set speaker volume percent 0-100",
        "inputSchema": {
            "type": "object",
            "properties": {"percent": {"type": "integer", "minimum": 0, "maximum": 100}},
            "required": ["percent"],
        },
    },
    {
        "name": "volume_adjust",
        "description": "Adjust speaker volume by delta (-100..100)",
        "inputSchema": {
            "type": "object",
            "properties": {
                "delta": {"type": "integer", "minimum": -100, "maximum": 100}
            },
            "required": ["delta"],
        },
    },
    {
        "name": "volume_mute",
        "description": "Mute or unmute the speaker (HDMI sink)",
        "inputSchema": {
            "type": "object",
            "properties": {"muted": {"type": "boolean"}},
            "required": ["muted"],
        },
    },
]


def dispatch_rpc(req: dict[str, Any]) -> dict[str, Any] | None:
    """Handle one JSON-RPC message. Returns a response dict, or None for notifications."""
    method = req.get("method")
    req_id = req.get("id")
    params = req.get("params") or {}

    # Notifications (no id) — accept and produce no body.
    if req_id is None and isinstance(method, str) and method.startswith("notifications/"):
        return None

    if method == "initialize":
        result: Any = {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "comstar-terminal", "version": "0.3.0"},
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
        # Client response — ignore.
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
        sys.stderr.write("[terminal_mcp] " + (format % args) + "\n")

    def _cors(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        if self.path.split("?", 1)[0] not in ("/mcp", "/"):
            self.send_error(404)
            return
        # Optional SSE listen — not required for tool calls; advertise no stream.
        self.send_response(405)
        self._cors()
        self.send_header("Allow", "POST, OPTIONS")
        self.end_headers()

    def do_DELETE(self) -> None:  # noqa: N802
        self.send_response(405)
        self._cors()
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
        # Notifications / client responses → 202
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
        # Session id optional; set on initialize for clients that expect it.
        if req.get("method") == "initialize":
            self.send_header("Mcp-Session-Id", uuid.uuid4().hex)
        self.end_headers()
        self.wfile.write(body)


def main_http(host: str, port: int) -> None:
    httpd = ThreadingHTTPServer((host, port), _McpHandler)
    # Print ready line for bootstrap to scrape.
    sys.stderr.write(f"terminal_mcp_http_ready host={host} port={httpd.server_address[1]}\n")
    sys.stderr.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


def main() -> None:
    parser = argparse.ArgumentParser(description="COMSTAR terminal MCP")
    parser.add_argument(
        "--http",
        action="store_true",
        help="Serve streamable HTTP MCP on loopback (default when COMSTAR_MCP_HTTP=1)",
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0, help="0 = ephemeral")
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
            port = int(env_port) if env_port.isdigit() else 0
        main_http(args.host, port)
    else:
        main_stdio()


if __name__ == "__main__":
    main()
