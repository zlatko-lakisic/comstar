"""COMSTAR LDAP planner MCP — lookup_user / list_comstar_users (P2.3).

Wraps the directory sidecar HTTP API. Session open must NOT depend on this MCP
(ADR 0005 / CONTRACTS §3b). Overlay agents may set guest_allowed: false.

Env:
  COMSTAR_DIRECTORY_URL  — sidecar base (default http://127.0.0.1:8780)
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

DIR_URL = os.environ.get("COMSTAR_DIRECTORY_URL", "http://127.0.0.1:8780").rstrip("/")

TOOLS: list[dict[str, Any]] = [
    {
        "name": "lookup_user",
        "description": (
            "Look up a COMSTAR FreeIPA person by uid. Returns displayName, "
            "groups, faceId/voiceId when enrolled. Does not open sessions."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "uid": {"type": "string", "description": "IPA uid"},
            },
            "required": ["uid"],
        },
    },
    {
        "name": "list_comstar_users",
        "description": "List people with objectClass=comstarPerson (capped).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "limit": {"type": "integer", "minimum": 1, "maximum": 200},
            },
        },
    },
]


def _ok(result: dict[str, Any]) -> dict[str, Any]:
    return {"ok": True, **result}


def _err(msg: str) -> dict[str, Any]:
    return {"ok": False, "error": msg}


def _get_json(path: str) -> tuple[dict[str, Any] | None, str | None, int]:
    url = f"{DIR_URL}{path}"
    try:
        req = Request(url, method="GET", headers={"Accept": "application/json"})
        with urlopen(req, timeout=8) as resp:
            body = resp.read().decode("utf-8")
            code = getattr(resp, "status", 200)
            data = json.loads(body) if body else {}
            if not isinstance(data, dict):
                return None, "invalid_json", code
            return data, None, code
    except HTTPError as e:
        try:
            detail = e.read().decode("utf-8")
            data = json.loads(detail) if detail else {}
        except Exception:  # noqa: BLE001
            data = {}
        msg = data.get("error") if isinstance(data, dict) else str(e)
        return None, str(msg or e), int(e.code)
    except URLError as e:
        return None, f"directory_unreachable:{e}", 503
    except Exception as e:  # noqa: BLE001
        return None, str(e), 503


def handle_tool(name: str, args: dict[str, Any]) -> dict[str, Any]:
    if name == "lookup_user":
        uid = str(args.get("uid") or "").strip()
        if not uid:
            return _err("missing_uid")
        data, err, code = _get_json(f"/v1/lookup?uid={quote(uid)}")
        if err:
            if code == 404:
                return _ok({"found": False, "uid": uid})
            return _err(err)
        assert data is not None
        return _ok({"found": True, "user": data})

    if name == "list_comstar_users":
        limit = args.get("limit", 50)
        try:
            limit_i = int(limit)
        except (TypeError, ValueError):
            limit_i = 50
        data, err, _code = _get_json(f"/v1/users?limit={limit_i}")
        if err:
            return _err(err)
        assert data is not None
        return _ok(
            {
                "users": data.get("users") or [],
                "count": data.get("count") or 0,
            }
        )

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
            "serverInfo": {"name": "comstar-ldap", "version": "0.1.0"},
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
        sys.stderr.write("[ldap_mcp] " + (format % args) + "\n")

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
            body = json.dumps({"ok": True, "service": "comstar-ldap"}).encode()
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
    sys.stderr.write(f"ldap_mcp_http_ready host={host} port={httpd.server_address[1]}\n")
    sys.stderr.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


def main() -> None:
    parser = argparse.ArgumentParser(description="COMSTAR LDAP planner MCP")
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
            port = int(env_port) if env_port.isdigit() else 8794
        main_http(args.host, port)
    else:
        main_stdio()


if __name__ == "__main__":
    main()
