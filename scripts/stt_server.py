#!/usr/bin/env python3
"""COMSTAR STT — sherpa-onnx Moonshine (OpenAI-compatible POST /v1/audio/transcriptions).

Pi-tuned replacement for faster-whisper. No PyTorch.

  pip install -r scripts/requirements-sherpa.txt
  COMSTAR_SHERPA_STT_DIR=/opt/comstar/models/sherpa/stt-moonshine-base \\
    python scripts/stt_server.py

Env:
  COMSTAR_SHERPA_STT_DIR  model directory (preprocess/encode/… onnx + tokens.txt)
  COMSTAR_STT_THREADS     onnx threads (default 2)
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


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


def _wav_to_float32(path: Path) -> tuple[Any, int]:
    import numpy as np

    with wave.open(str(path), "rb") as w:
        rate = w.getframerate()
        ch = w.getnchannels()
        sw = w.getsampwidth()
        n = w.getnframes()
        raw = w.readframes(n)
    if sw != 2:
        raise ValueError(f"unsupported sampwidth={sw}")
    samples = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    if ch > 1:
        samples = samples.reshape(-1, ch).mean(axis=1)
    return samples, rate


def _find_moonshine(dir_path: Path) -> dict[str, Path]:
    """Resolve Moonshine v1 (4 onnx) or v2 (encoder+decoder) layouts."""
    # v1 int8 layout from sherpa releases
    v1 = {
        "preprocessor": dir_path / "preprocess.onnx",
        "encoder": dir_path / "encode.int8.onnx",
        "uncached_decoder": dir_path / "uncached_decode.int8.onnx",
        "cached_decoder": dir_path / "cached_decode.int8.onnx",
        "tokens": dir_path / "tokens.txt",
    }
    if all(p.is_file() for p in v1.values()):
        return {"kind": "v1", **v1}  # type: ignore[dict-item]

    # alternate non-int8 names
    v1b = {
        "preprocessor": dir_path / "preprocess.onnx",
        "encoder": dir_path / "encode.onnx",
        "uncached_decoder": dir_path / "uncached_decode.onnx",
        "cached_decoder": dir_path / "cached_decode.onnx",
        "tokens": dir_path / "tokens.txt",
    }
    if all(p.is_file() for p in v1b.values()):
        return {"kind": "v1", **v1b}  # type: ignore[dict-item]

    enc = next(dir_path.glob("encoder*"), None)
    dec = next(dir_path.glob("decoder*"), None)
    tok = dir_path / "tokens.txt"
    if enc and dec and tok.is_file():
        return {"kind": "v2", "encoder": enc, "decoder": dec, "tokens": tok}

    raise FileNotFoundError(f"No Moonshine model files in {dir_path}")


class SttHandler(BaseHTTPRequestHandler):
    model_dir: Path | None = None
    threads = 2
    _recognizer = None

    @classmethod
    def load_model(cls) -> None:
        if cls._recognizer is not None:
            return
        try:
            import sherpa_onnx
        except ImportError as exc:
            print(
                "sherpa-onnx missing. pip install -r scripts/requirements-sherpa.txt",
                file=sys.stderr,
            )
            raise SystemExit(2) from exc

        assert cls.model_dir is not None
        files = _find_moonshine(cls.model_dir)
        t0 = time.time()
        if files["kind"] == "v1":
            cls._recognizer = sherpa_onnx.OfflineRecognizer.from_moonshine(
                preprocessor=str(files["preprocessor"]),
                encoder=str(files["encoder"]),
                uncached_decoder=str(files["uncached_decoder"]),
                cached_decoder=str(files["cached_decoder"]),
                tokens=str(files["tokens"]),
                num_threads=cls.threads,
                provider="cpu",
            )
        else:
            cls._recognizer = sherpa_onnx.OfflineRecognizer.from_moonshine_v2(
                encoder=str(files["encoder"]),
                decoder=str(files["decoder"]),
                tokens=str(files["tokens"]),
                num_threads=cls.threads,
                provider="cpu",
            )
        print(
            f"[stt] moonshine {files['kind']} loaded from {cls.model_dir} "
            f"in {time.time() - t0:.1f}s threads={cls.threads}",
            file=sys.stderr,
        )

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write(
            "%s - - [%s] %s\n"
            % (self.address_string(), self.log_date_time_string(), fmt % args)
        )

    def do_GET(self) -> None:  # noqa: N802
        if self.path in ("/", "/health"):
            body = b'{"ok":true,"engine":"sherpa-moonshine"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404, "Not found")

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
        assert self._recognizer is not None

        Path("/tmp/comstar-last-utterance.wav").write_bytes(file_bytes)
        tmp = Path("/tmp/comstar-stt-in.wav")
        tmp.write_bytes(file_bytes)

        text = ""
        t0 = time.time()
        try:
            samples, rate = _wav_to_float32(tmp)
            # Very short / near-silent → empty (Moonshine is less hallucinatory
            # than Whisper, but still skip obvious blanks).
            import numpy as np

            rms = float(np.sqrt(np.mean(np.square(samples)))) if samples.size else 0.0
            if samples.size < rate * 0.25 or rms < 0.008:
                print(f"[stt] skip short/quiet bytes={len(file_bytes)} rms={rms:.4f}", file=sys.stderr)
                text = ""
            else:
                stream = self._recognizer.create_stream()
                stream.accept_waveform(rate, samples)
                self._recognizer.decode_stream(stream)
                text = (stream.result.text or "").strip()
            print(
                f"[stt] bytes={len(file_bytes)} rms={rms:.4f} "
                f"ms={(time.time() - t0) * 1000:.0f} text={text!r}",
                file=sys.stderr,
            )
        except Exception as exc:  # noqa: BLE001
            print(f"[stt] error: {exc}", file=sys.stderr)
            text = ""
        finally:
            tmp.unlink(missing_ok=True)

        payload = json.dumps({"text": text}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8090)
    parser.add_argument(
        "--model-dir",
        default=os.environ.get(
            "COMSTAR_SHERPA_STT_DIR",
            "/opt/comstar/models/sherpa/stt-moonshine-base",
        ),
    )
    parser.add_argument(
        "--threads",
        type=int,
        default=int(os.environ.get("COMSTAR_STT_THREADS", "2")),
    )
    args = parser.parse_args()

    SttHandler.model_dir = Path(args.model_dir)
    SttHandler.threads = max(1, args.threads)
    if not SttHandler.model_dir.is_dir():
        print(f"Model dir missing: {SttHandler.model_dir}", file=sys.stderr)
        print("Run scripts/install_sherpa_models.sh first.", file=sys.stderr)
        return 1

    # Eager load so first request is not a multi-second stall.
    SttHandler.load_model()

    server = ThreadingHTTPServer((args.host, args.port), SttHandler)
    print(f"COMSTAR STT (sherpa/moonshine) on http://{args.host}:{args.port}", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.", file=sys.stderr)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
