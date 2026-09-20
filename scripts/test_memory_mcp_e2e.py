#!/usr/bin/env python3
"""E2E: memory server + memory_mcp tools for a seeded userid."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
MCP = ROOT / "mcp"


def _load_memory_server(env_dir: str):
    path = SCRIPTS / "comstar_memory_server.py"
    spec = importlib.util.spec_from_file_location("comstar_memory_server", path)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    os.environ["COMSTAR_MEMORY_DIR"] = env_dir
    spec.loader.exec_module(mod)
    return mod


class MemoryMcpE2ETest(unittest.TestCase):
    def test_tools_against_live_memory_server(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            mem = _load_memory_server(tmp)
            # Seed via module API
            mem.upsert_fact(
                "zlatko",
                {
                    "id": "tea1",
                    "kind": "preference",
                    "text": "Resident prefers Assam tea",
                },
            )
            mem.put_rolling(
                "zlatko",
                {
                    "turns": [
                        {"role": "user", "text": "remember tea", "ts": 1},
                        {"role": "assistant", "text": "noted", "ts": 2},
                    ]
                },
            )

            # Start memory HTTP on ephemeral port
            port_box: list[int] = []

            def _serve() -> None:
                from http.server import ThreadingHTTPServer

                # Rebind Handler from module
                httpd = ThreadingHTTPServer(
                    ("127.0.0.1", 0), mem.Handler  # type: ignore[attr-defined]
                )
                port_box.append(httpd.server_address[1])
                httpd.timeout = 0.5
                while not getattr(httpd, "_stop", False):
                    httpd.handle_request()

            # Use module's serve pattern — start script subprocess instead
            env = os.environ.copy()
            env["COMSTAR_MEMORY_DIR"] = tmp
            env["COMSTAR_MEMORY_HOST"] = "127.0.0.1"
            env["COMSTAR_MEMORY_PORT"] = "0"
            # Port 0 may not be supported — pick free port
            import socket

            sock = socket.socket()
            sock.bind(("127.0.0.1", 0))
            mem_port = sock.getsockname()[1]
            sock.close()
            env["COMSTAR_MEMORY_PORT"] = str(mem_port)
            proc = subprocess.Popen(
                [sys.executable, str(SCRIPTS / "comstar_memory_server.py")],
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
            try:
                deadline = time.time() + 5
                while time.time() < deadline:
                    try:
                        import urllib.request

                        with urllib.request.urlopen(
                            f"http://127.0.0.1:{mem_port}/health", timeout=0.5
                        ) as r:
                            if r.status == 200:
                                break
                    except Exception:
                        time.sleep(0.1)
                else:
                    self.fail("memory server did not become healthy")

                # Re-seed after server start (server has its own connection)
                import urllib.request

                req = urllib.request.Request(
                    f"http://127.0.0.1:{mem_port}/v1/facts/zlatko",
                    data=json.dumps(
                        {
                            "id": "tea1",
                            "kind": "preference",
                            "text": "Resident prefers Assam tea",
                        }
                    ).encode(),
                    headers={"Content-Type": "application/json"},
                    method="POST",
                )
                urllib.request.urlopen(req, timeout=2).read()
                req2 = urllib.request.Request(
                    f"http://127.0.0.1:{mem_port}/v1/memory/zlatko",
                    data=json.dumps(
                        {
                            "turns": [
                                {"role": "user", "text": "hi", "ts": 1},
                                {"role": "assistant", "text": "hello", "ts": 2},
                            ]
                        }
                    ).encode(),
                    headers={"Content-Type": "application/json"},
                    method="PUT",
                )
                urllib.request.urlopen(req2, timeout=2).read()

                sys.path.insert(0, str(MCP))
                import memory_mcp.server as mcp

                mcp.MEMORY_BASE = f"http://127.0.0.1:{mem_port}"
                mcp.USERID = "zlatko"
                sf = mcp.handle_tool("search_facts", {"query": "tea"})
                self.assertTrue(sf["ok"])
                self.assertGreaterEqual(sf["count"], 1)
                rt = mcp.handle_tool("recent_turns", {})
                self.assertTrue(rt["ok"])
                self.assertGreaterEqual(rt["count"], 1)
                rc = mcp.handle_tool("recall_context", {"query": "tea"})
                self.assertTrue(rc["ok"])
                self.assertGreaterEqual(len(rc["facts"]), 1)
            finally:
                proc.terminate()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()


if __name__ == "__main__":
    unittest.main()
