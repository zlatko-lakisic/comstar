#!/usr/bin/env python3
"""COMSTAR terminal MCP (stdio JSON-RPC) — CONTRACTS §5 tools.

Sleep/volume call bridge loopback HTTP; display/tone/mic remain soft-state stubs.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
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
                "isError": not payload.get("ok", True) and "error" in payload,
            }
        elif method == "initialize":
            result = {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "comstar-terminal", "version": "0.2.0"},
            }
        else:
            result = {"error": f"unsupported method {method}"}
        if req_id is not None:
            sys.stdout.write(
                json.dumps({"jsonrpc": "2.0", "id": req_id, "result": result}) + "\n"
            )
            sys.stdout.flush()


if __name__ == "__main__":
    main()
