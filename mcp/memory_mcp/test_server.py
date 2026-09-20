#!/usr/bin/env python3
"""Unit tests for memory_mcp tool handlers (mock memory REST)."""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any
from urllib.parse import parse_qs, urlparse

import memory_mcp.server as server


class _MemoryHandler(BaseHTTPRequestHandler):
    facts: list[dict[str, Any]] = []
    turns: list[dict[str, Any]] = []

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A003
        return

    def _reply(self, code: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        if path.startswith("/v1/facts/"):
            qs = parse_qs(parsed.query)
            q = (qs.get("q") or [""])[0].lower()
            facts = list(_MemoryHandler.facts)
            if q:
                facts = [f for f in facts if q in f.get("text", "").lower()]
            self._reply(200, {"userid": "zlatko", "facts": facts})
            return
        if path.startswith("/v1/memory/"):
            self._reply(200, {"userid": "zlatko", "turns": list(_MemoryHandler.turns)})
            return
        self._reply(404, {"ok": False})


def test_tools_against_mock_memory() -> None:
    httpd = HTTPServer(("127.0.0.1", 0), _MemoryHandler)
    port = httpd.server_address[1]
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        server.MEMORY_BASE = f"http://127.0.0.1:{port}"
        server.USERID = "zlatko"
        _MemoryHandler.facts = [
            {
                "id": "tea",
                "kind": "preference",
                "text": "Resident prefers Assam tea",
            }
        ]
        _MemoryHandler.turns = [
            {"role": "user", "text": "hello", "ts": 1},
            {"role": "assistant", "text": "hi", "ts": 2},
        ]

        sf = server.handle_tool("search_facts", {"query": "tea"})
        assert sf["ok"] is True
        assert sf["count"] == 1
        assert "Assam" in sf["facts"][0]["text"]

        rt = server.handle_tool("recent_turns", {"limit": 10})
        assert rt["ok"] is True
        assert rt["count"] == 2

        rc = server.handle_tool("recall_context", {"query": "tea"})
        assert rc["ok"] is True
        assert len(rc["facts"]) == 1
        assert len(rc["turns"]) == 2

        bad = server.handle_tool("search_facts", {})
        # userid from env
        assert bad["ok"] is True

        server.USERID = ""
        missing = server.handle_tool("search_facts", {})
        assert missing["ok"] is False
        assert missing["error"] == "userid_required"
    finally:
        httpd.shutdown()


if __name__ == "__main__":
    test_tools_against_mock_memory()
    print("ok")
