#!/usr/bin/env python3
"""Minimal COMSTAR terminal MCP (stdio JSON-RPC) — CONTRACTS §5 tools.

Exposes set_display, play_tone, mic_status, screen_state for AO tunnel wiring.
Phase 1: in-process state only; hardware hooks are no-ops that return ok.
"""

from __future__ import annotations

import json
import sys
from typing import Any

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
]


def main() -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        method = req.get("method")
        req_id = req.get("id")
        params = req.get("params") or {}
        if method == "tools/list":
            result: Any = {"tools": TOOLS}
        elif method == "tools/call":
            name = params.get("name", "")
            args = params.get("arguments") or {}
            payload = handle_tool(name, args)
            result = {
                "content": [{"type": "text", "text": json.dumps(payload)}],
                "isError": not payload.get("ok", True)
                and "error" in payload,
            }
        elif method == "initialize":
            result = {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "comstar-terminal", "version": "0.1.0"},
            }
        else:
            result = {"error": f"unsupported method {method}"}
        if req_id is not None:
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": req_id, "result": result}) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
