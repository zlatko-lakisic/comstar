#!/usr/bin/env python3
"""COMSTAR memory MCP — CONTRACTS §5 dial-back tools.

Loopback streamable HTTP on ``/mcp``. Bridge registers
``tunnel://session-mcp/comstar_memory`` → session id ``client.comstar_memory``.

Talks to ``scripts/comstar_memory_server.py`` via ``COMSTAR_MEMORY_URL``
(default ``http://127.0.0.1:8792``). Tools are scoped to ``COMSTAR_MEMORY_USERID``.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

MEMORY_BASE = os.environ.get("COMSTAR_MEMORY_URL", "http://127.0.0.1:8792").rstrip(
    "/"
)
USERID = os.environ.get("COMSTAR_MEMORY_USERID", "").strip().lower()


def _ok(result: dict[str, Any]) -> dict[str, Any]:
    return {"ok": True, **result}


def _userid(args: dict[str, Any] | None = None) -> str | None:
    if args:
        raw = args.get("userid")
        if isinstance(raw, str) and raw.strip():
            return raw.strip().lower()
    if USERID and USERID not in ("guest", "unknown"):
        return USERID
    return None


def _http_json(method: str, path: str, body: dict[str, Any] | None = None) -> dict[str, Any]:
    url = f"{MEMORY_BASE}{path}"
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
            parsed = json.loads(raw)
            return parsed if isinstance(parsed, dict) else {"ok": True, "data": parsed}
    except urllib.error.HTTPError as e:
        try:
            payload = json.loads(e.read().decode("utf-8"))
            if isinstance(payload, dict):
                return payload
        except Exception:
            pass
        return {"ok": False, "error": f"http_{e.code}"}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e)}


def search_facts(userid: str, query: str = "", limit: int = 8) -> dict[str, Any]:
    limit = max(1, min(int(limit), 32))
    q = urllib.parse.urlencode({"q": query or "", "limit": str(limit)})
    path = f"/v1/facts/{urllib.parse.quote(userid)}?{q}"
    res = _http_json("GET", path)
    if res.get("ok") is False and "error" in res:
        return res
    facts = res.get("facts") if isinstance(res.get("facts"), list) else []
    return _ok({"userid": userid, "facts": facts, "count": len(facts)})


def recent_turns(userid: str, limit: int = 8) -> dict[str, Any]:
    limit = max(1, min(int(limit), 40))
    path = f"/v1/memory/{urllib.parse.quote(userid)}"
    res = _http_json("GET", path)
    if res.get("ok") is False and "error" in res:
        return res
    turns = res.get("turns") if isinstance(res.get("turns"), list) else []
    if len(turns) > limit:
        turns = turns[-limit:]
    return _ok({"userid": userid, "turns": turns, "count": len(turns)})


def recall_context(userid: str, query: str = "", fact_limit: int = 6, turn_limit: int = 4) -> dict[str, Any]:
    facts = search_facts(userid, query=query, limit=fact_limit)
    turns = recent_turns(userid, limit=turn_limit)
    if facts.get("ok") is False:
        return facts
    if turns.get("ok") is False:
        return turns
    return _ok(
        {
            "userid": userid,
            "query": query,
            "facts": facts.get("facts", []),
            "turns": turns.get("turns", []),
        }
    )


def handle_tool(name: str, args: dict[str, Any]) -> dict[str, Any]:
    uid = _userid(args)
    if not uid:
        return {"ok": False, "error": "userid_required"}

    if name == "search_facts":
        q = args.get("query") or args.get("q") or ""
        if not isinstance(q, str):
            q = ""
        limit = args.get("limit", 8)
        try:
            limit_i = int(limit)
        except (TypeError, ValueError):
            limit_i = 8
        return search_facts(uid, query=q, limit=limit_i)

    if name == "recent_turns":
        limit = args.get("limit", 8)
        try:
            limit_i = int(limit)
        except (TypeError, ValueError):
            limit_i = 8
        return recent_turns(uid, limit=limit_i)

    if name == "recall_context":
        q = args.get("query") or args.get("q") or ""
        if not isinstance(q, str):
            q = ""
        try:
            fl = int(args.get("fact_limit", 6))
        except (TypeError, ValueError):
            fl = 6
        try:
            tl = int(args.get("turn_limit", 4))
        except (TypeError, ValueError):
            tl = 4
        return recall_context(uid, query=q, fact_limit=fl, turn_limit=tl)

    return {"ok": False, "error": f"unknown tool: {name}"}


TOOLS = [
    {
        "name": "search_facts",
        "description": (
            "Search durable resident facts (prefs, remember-that notes). "
            "Empty query returns most recent facts."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "FTS / substring query"},
                "limit": {"type": "integer", "minimum": 1, "maximum": 32},
                "userid": {
                    "type": "string",
                    "description": "Optional override; defaults to session userid",
                },
            },
        },
    },
    {
        "name": "recent_turns",
        "description": (
            "Return the most recent rolling conversation turns for this resident "
            "(not stuffed into every prompt — call when follow-up context is thin)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "limit": {"type": "integer", "minimum": 1, "maximum": 40},
                "userid": {"type": "string"},
            },
        },
    },
    {
        "name": "recall_context",
        "description": (
            "Combined facts + recent turns for a preference / continuity question. "
            "Prefer this over inventing prior conversation."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "fact_limit": {"type": "integer", "minimum": 1, "maximum": 32},
                "turn_limit": {"type": "integer", "minimum": 1, "maximum": 40},
                "userid": {"type": "string"},
            },
        },
    },
]


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
            "serverInfo": {"name": "comstar-memory", "version": "0.1.0"},
        }
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        name = params.get("name") if isinstance(params, dict) else None
        args = params.get("arguments") if isinstance(params, dict) else {}
        if not isinstance(name, str):
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32602, "message": "name required"},
            }
        if not isinstance(args, dict):
            args = {}
        tool_result = handle_tool(name, args)
        result = {
            "content": [
                {"type": "text", "text": json.dumps(tool_result, ensure_ascii=False)}
            ],
            "isError": tool_result.get("ok") is False,
        }
    else:
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32601, "message": f"unknown method: {method}"},
        }

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
        sys.stderr.write("[memory_mcp] " + (format % args) + "\n")

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
                {
                    "jsonrpc": "2.0",
                    "id": None,
                    "error": {"code": -32700, "message": "parse error"},
                }
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
    sys.stderr.write(
        f"memory_mcp_http_ready host={host} port={httpd.server_address[1]}\n"
    )
    sys.stderr.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


def main() -> None:
    parser = argparse.ArgumentParser(description="COMSTAR memory MCP")
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
            port = int(env_port) if env_port.isdigit() else 0
        main_http(args.host, port)
    else:
        main_stdio()


if __name__ == "__main__":
    main()
