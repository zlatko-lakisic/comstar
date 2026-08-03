#!/usr/bin/env python3
"""Unit tests for terminal MCP sleep/volume → bridge HTTP mapping."""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any

import terminal_mcp.server as server


class _Handler(BaseHTTPRequestHandler):
    calls: list[tuple[str, str, dict[str, Any]]] = []

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A003
        return

    def _read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def _reply(self, code: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        self.calls.append(("GET", self.path, {}))
        if self.path == "/control/sleep":
            self._reply(200, {"ok": True, "sleeping": False})
        elif self.path == "/control/volume":
            self._reply(200, {"ok": True, "percent": 40, "muted": False})
        else:
            self._reply(404, {"ok": False})

    def do_POST(self) -> None:  # noqa: N802
        body = self._read_json()
        self.calls.append(("POST", self.path, body))
        if self.path == "/control/sleep":
            self._reply(200, {"ok": True, "state": "sleeping"})
        elif self.path == "/control/volume":
            self._reply(
                200,
                {
                    "ok": True,
                    "percent": body.get("percent", 40),
                    "muted": body.get("muted", False),
                },
            )
        else:
            self._reply(404, {"ok": False})


def test_tools_map_to_http() -> None:
    httpd = HTTPServer(("127.0.0.1", 0), _Handler)
    port = httpd.server_address[1]
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        server.CONTROL_BASE = f"http://127.0.0.1:{port}"
        _Handler.calls.clear()

        assert server.handle_tool("sleep_enter", {})["ok"] is True
        assert server.handle_tool("sleep_status", {})["sleeping"] is False
        assert server.handle_tool("volume_get", {})["percent"] == 40
        assert server.handle_tool("volume_set", {"percent": 70})["ok"] is True
        assert server.handle_tool("volume_adjust", {"delta": -10})["ok"] is True
        assert server.handle_tool("volume_mute", {"muted": True})["ok"] is True

        paths = [(m, p) for m, p, _ in _Handler.calls]
        assert ("POST", "/control/sleep") in paths
        assert ("GET", "/control/sleep") in paths
        assert ("GET", "/control/volume") in paths
        assert ("POST", "/control/volume") in paths
    finally:
        httpd.shutdown()


if __name__ == "__main__":
    test_tools_map_to_http()
    print("ok")
