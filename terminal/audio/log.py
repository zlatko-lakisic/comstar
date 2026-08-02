"""Structured JSON logging for the COMSTAR audio process."""

from __future__ import annotations

import json
import os
import sys
import time
from typing import Any

_PROC = "audio"
_LEVELS = {"debug": 0, "info": 1, "warn": 2, "error": 3}
_LEVEL = os.environ.get("COMSTAR_LOG", "info").strip().lower()


def _should_log(level: str) -> bool:
    return _LEVELS.get(level, 1) >= _LEVELS.get(_LEVEL, 1)


def log_event(
    level: str,
    evt: str,
    msg: str,
    *,
    turn_id: str | None = None,
    data: dict[str, Any] | None = None,
) -> None:
    if not _should_log(level):
        return
    entry: dict[str, Any] = {
        "ts": int(time.time() * 1000),
        "level": level,
        "proc": _PROC,
        "evt": evt,
        "msg": msg,
    }
    if turn_id is not None:
        entry["turn_id"] = turn_id
    if data:
        entry["data"] = data
    sys.stdout.write(json.dumps(entry, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def log_info(evt: str, msg: str, **kwargs: Any) -> None:
    log_event("info", evt, msg, **kwargs)


def log_warn(evt: str, msg: str, **kwargs: Any) -> None:
    log_event("warn", evt, msg, **kwargs)


def log_error(evt: str, msg: str, **kwargs: Any) -> None:
    log_event("error", evt, msg, **kwargs)


class Span:
    def __init__(self, name: str, *, turn_id: str | None = None) -> None:
        self.name = name
        self.turn_id = turn_id
        self._start = time.monotonic()
        self._closed = False

    def close(self, **data: Any) -> None:
        if self._closed:
            return
        self._closed = True
        ms = int((time.monotonic() - self._start) * 1000)
        payload = {"name": self.name, "ms": ms, **data}
        log_info("span", f"{self.name} completed", turn_id=self.turn_id, data=payload)
