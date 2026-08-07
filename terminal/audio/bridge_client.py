"""WebSocket client for the COMSTAR bridge audio port."""

from __future__ import annotations

import asyncio
import json
import os
import random
import time
import uuid
from typing import Any, Awaitable, Callable

import websockets
from websockets.asyncio.client import ClientConnection

from log import log_error, log_info, log_warn

MessageHandler = Callable[[dict[str, Any]], Awaitable[None] | None]

ENVELOPE_VERSION = 1


def _new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4()}"


def wrap_message(msg_type: str, data: dict[str, Any] | None = None, *, turn_id: str | None = None) -> str:
    envelope = {
        "v": ENVELOPE_VERSION,
        "id": _new_id("msg"),
        "type": msg_type,
        "ts": int(time.time() * 1000),
        "turn_id": turn_id,
        "data": data or {},
    }
    return json.dumps(envelope)


class BridgeClient:
    def __init__(
        self,
        url: str | None = None,
        *,
        on_message: MessageHandler | None = None,
        min_backoff: float = 0.5,
        max_backoff: float = 5.0,
    ) -> None:
        self.url = url or os.environ.get("COMSTAR_BRIDGE", "ws://127.0.0.1:8778/audio")
        self.on_message = on_message
        self.min_backoff = min_backoff
        self.max_backoff = max_backoff
        self._stop = asyncio.Event()
        self._ws: ClientConnection | None = None

    async def run(self) -> None:
        attempt = 0
        while not self._stop.is_set():
            try:
                log_info("ws_connecting", "Connecting to bridge", data={"url": self.url})
                async with websockets.connect(self.url) as ws:
                    self._ws = ws
                    attempt = 0
                    await ws.send(wrap_message("ready", {"status": "audio_ok"}))
                    log_info("ws_connected", "Connected to bridge")
                    async for raw in ws:
                        if self._stop.is_set():
                            break
                        await self._handle_raw(raw)
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001 — reconnect on any failure
                log_warn("ws_error", str(exc), data={"url": self.url})
            finally:
                self._ws = None

            if self._stop.is_set():
                break

            attempt += 1
            # Full jitter: delay ~ U(0, min(cap, base * 2^(attempt-1)))
            ceiling = min(self.max_backoff, self.min_backoff * (2 ** (attempt - 1)))
            delay = random.uniform(0, ceiling)
            log_info("ws_reconnect", "Reconnecting after backoff", data={"delay_s": round(delay, 2)})
            try:
                await asyncio.wait_for(self._stop.wait(), timeout=delay)
            except asyncio.TimeoutError:
                pass

    async def _handle_raw(self, raw: str | bytes) -> None:
        if isinstance(raw, bytes):
            return
        try:
            envelope = json.loads(raw)
        except json.JSONDecodeError:
            log_warn("ws_malformed", "Dropped malformed message")
            return
        if not isinstance(envelope, dict):
            return
        msg_type = envelope.get("type")
        if msg_type in {"ping"}:
            await self.send("pong")
            return
        if self.on_message is not None:
            result = self.on_message(envelope)
            if asyncio.iscoroutine(result):
                await result

    async def send(self, msg_type: str, data: dict[str, Any] | None = None, *, turn_id: str | None = None) -> None:
        if self._ws is None:
            log_warn("ws_send_skipped", "Not connected", data={"type": msg_type})
            return
        await self._ws.send(wrap_message(msg_type, data, turn_id=turn_id))

    async def send_binary(self, data: bytes) -> None:
        if self._ws is None:
            log_warn("ws_send_skipped", "Not connected", data={"type": "binary"})
            return
        await self._ws.send(data)

    async def stop(self) -> None:
        self._stop.set()
        if self._ws is not None:
            await self._ws.close()
        log_info("ws_stopped", "Bridge client stopped")
