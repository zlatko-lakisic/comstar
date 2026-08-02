#!/usr/bin/env python3
"""Minimal OpenAI-compatible STT server for COMSTAR dev (POST /v1/audio/transcriptions).

Requires faster-whisper. Bind 127.0.0.1:8090 by default.

Usage:
  python3 -m venv .venv-stt && source .venv-stt/bin/activate
  pip install -r scripts/requirements-stt.txt
  python scripts/stt_server.py

Then set COMSTAR_STT_URL=http://127.0.0.1:8090 on the bridge.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


def _require_faster_whisper():
    try:
        from faster_whisper import WhisperModel  # noqa: F401
    except ImportError as exc:
        print(
            "faster-whisper is not installed.\n"
            "  pip install -r scripts/requirements-stt.txt\n"
            "Then re-run this script.",
            file=sys.stderr,
        )
        raise SystemExit(2) from exc
    from faster_whisper import WhisperModel

    return WhisperModel


def _parse_multipart(body: bytes, content_type: str) -> dict[str, Any]:
    match = re.search(r"boundary=([^;\s]+)", content_type)
    if not match:
        raise ValueError("multipart boundary missing")
    boundary = match.group(1).strip('"').encode()
    parts: dict[str, Any] = {"files": {}}
    for chunk in body.split(b"--" + boundary):
        chunk = chunk.strip(b"\r\n-")
        if not chunk or chunk == b"--":
            continue
        header_blob, _, payload = chunk.partition(b"\r\n\r\n")
        headers = header_blob.decode("utf-8", errors="replace")
        name_match = re.search(r'name="([^"]+)"', headers)
        if not name_match:
            continue
        name = name_match.group(1)
        if 'filename="' in headers:
            parts["files"][name] = payload.rstrip(b"\r\n")
        else:
            parts[name] = payload.rstrip(b"\r\n").decode("utf-8", errors="replace")
    return parts


class SttHandler(BaseHTTPRequestHandler):
    model_name = "base"
    _model = None

    @classmethod
    def load_model(cls) -> None:
        if cls._model is not None:
            return
        WhisperModel = _require_faster_whisper()
        cls._model = WhisperModel(cls.model_name, device="cpu", compute_type="int8")

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), fmt % args))

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/v1/audio/transcriptions":
            self.send_error(404, "Not found")
            return

        content_type = self.headers.get("Content-Type", "")
        if "multipart/form-data" not in content_type:
            self.send_error(400, "Expected multipart/form-data")
            return

        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        try:
            parsed = _parse_multipart(body, content_type)
        except ValueError as exc:
            self.send_error(400, str(exc))
            return

        file_bytes = parsed.get("files", {}).get("file")
        if not file_bytes:
            self.send_error(400, "Missing file field")
            return

        self.load_model()
        assert self._model is not None

        suffix = ".wav"
        with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
            tmp.write(file_bytes)
            tmp_path = Path(tmp.name)

        try:
            segments, _info = self._model.transcribe(str(tmp_path))
            text = " ".join(segment.text.strip() for segment in segments).strip()
        finally:
            tmp_path.unlink(missing_ok=True)

        payload = json.dumps({"text": text}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:  # noqa: N802
        if self.path in ("/", "/health"):
            body = b'{"ok":true}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404, "Not found")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8090)
    parser.add_argument("--model", default="base", help="faster-whisper model size/name")
    args = parser.parse_args()

    SttHandler.model_name = args.model
    server = ThreadingHTTPServer((args.host, args.port), SttHandler)
    print(f"COMSTAR STT listening on http://{args.host}:{args.port}", file=sys.stderr)
    print("  POST /v1/audio/transcriptions  (multipart file field)", file=sys.stderr)
    print("  COMSTAR_STT_URL=http://127.0.0.1:8090", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.", file=sys.stderr)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
