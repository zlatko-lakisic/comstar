#!/usr/bin/env python3
"""Kokoro TTS sidecar — OpenAI-compatible POST /v1/audio/speech → audio/wav.

Much more natural than Piper VITS. Model dir must contain:
  model.onnx, voices.bin, tokens.txt, espeak-ng-data/

Env:
  COMSTAR_TTS_KOKORO_SID   default speaker id (0–53 for kokoro-en-v0_19)
  AGENTIC_SPEECH_TOKEN     optional bearer
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


# Friendly names → kokoro-en-v0_19 speaker ids (common US voices).
VOICE_ALIASES = {
    "af_heart": 0,
    "af_alloy": 1,
    "af_aoede": 2,
    "af_bella": 3,
    "af_jessica": 4,
    "af_kore": 5,
    "af_nicole": 6,
    "af_nova": 7,
    "af_river": 8,
    "af_sarah": 9,
    "af_sky": 10,
    "am_adam": 11,
    "am_echo": 12,
    "am_eric": 13,
    "am_fenrir": 14,
    "am_liam": 15,
    "am_michael": 16,
    "am_onyx": 17,
    "am_puck": 18,
    "am_santa": 19,
}


def _find_kokoro(dir_path: Path) -> dict[str, Path]:
    model = dir_path / "model.onnx"
    voices = dir_path / "voices.bin"
    tokens = dir_path / "tokens.txt"
    data_dir = dir_path / "espeak-ng-data"
    missing = [p.name for p in (model, voices, tokens) if not p.is_file()]
    if not data_dir.is_dir():
        missing.append("espeak-ng-data/")
    if missing:
        raise FileNotFoundError(f"Need {missing} in {dir_path}")
    return {
        "model": model,
        "voices": voices,
        "tokens": tokens,
        "data_dir": data_dir,
    }


def _write_wav(path: Path, samples: Any, sample_rate: int) -> None:
    import numpy as np

    pcm = np.asarray(samples, dtype=np.float32)
    pcm = np.clip(pcm, -1.0, 1.0)
    ints = (pcm * 32767.0).astype(np.int16)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sample_rate)
        w.writeframes(ints.tobytes())


def _resolve_sid(voice: Any, default_sid: int) -> int:
    if voice is None:
        return default_sid
    if isinstance(voice, (int, float)):
        return int(voice)
    s = str(voice).strip()
    if not s:
        return default_sid
    if s.isdigit():
        return int(s)
    key = s.lower().replace("-", "_")
    if key in VOICE_ALIASES:
        return VOICE_ALIASES[key]
    # bare names like "bella" / "heart"
    for name, sid in VOICE_ALIASES.items():
        if name.endswith(f"_{key}") or name == key:
            return sid
    return default_sid


class TtsHandler(BaseHTTPRequestHandler):
    model_dir: Path | None = None
    threads = 4
    provider = "cpu"
    default_sid = 0
    auth_token: str | None = None
    _tts = None

    @classmethod
    def load_model(cls) -> None:
        if cls._tts is not None:
            return
        import sherpa_onnx

        assert cls.model_dir is not None
        files = _find_kokoro(cls.model_dir)
        t0 = time.time()
        cfg = sherpa_onnx.OfflineTtsConfig(
            model=sherpa_onnx.OfflineTtsModelConfig(
                kokoro=sherpa_onnx.OfflineTtsKokoroModelConfig(
                    model=str(files["model"]),
                    voices=str(files["voices"]),
                    tokens=str(files["tokens"]),
                    data_dir=str(files["data_dir"]),
                ),
                provider=cls.provider,
                num_threads=cls.threads,
                debug=False,
            ),
            max_num_sentences=2,
        )
        if not cfg.validate():
            raise RuntimeError("Invalid OfflineTtsConfig")
        cls._tts = sherpa_onnx.OfflineTts(cfg)
        print(
            f"[tts] kokoro loaded from {cls.model_dir} "
            f"in {time.time() - t0:.1f}s threads={cls.threads} "
            f"provider={cls.provider} default_sid={cls.default_sid}",
            file=sys.stderr,
        )

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write(
            "%s - - [%s] %s\n"
            % (self.address_string(), self.log_date_time_string(), fmt % args)
        )

    def _unauthorized(self) -> bool:
        if not self.auth_token:
            return False
        header = self.headers.get("Authorization", "")
        expected = f"Bearer {self.auth_token}"
        if header.strip() != expected:
            self.send_error(401, "Unauthorized")
            return True
        return False

    def do_GET(self) -> None:  # noqa: N802
        if self.path in ("/", "/health"):
            body = json.dumps(
                {
                    "ok": True,
                    "engine": "sherpa-kokoro",
                    "model": "kokoro-en-v0_19",
                    "default_sid": self.default_sid,
                }
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404, "Not found")

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/v1/audio/speech":
            self.send_error(404, "Not found")
            return
        if self._unauthorized():
            return

        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8") or "{}")
        except json.JSONDecodeError:
            self.send_error(400, "invalid json")
            return

        text = (payload.get("text") or payload.get("input") or "").strip()
        if not text:
            self.send_error(400, "missing text")
            return
        if len(text) > 800:
            text = text[:800]

        sid = _resolve_sid(payload.get("voice"), self.default_sid)
        speed = payload.get("speed", 1.0)
        try:
            speed = float(speed)
        except (TypeError, ValueError):
            speed = 1.0
        speed = max(0.7, min(1.3, speed))

        self.load_model()
        assert self._tts is not None

        t0 = time.time()
        try:
            audio = self._tts.generate(text, sid=sid, speed=speed)
            samples = audio.samples
            rate = int(audio.sample_rate)
        except Exception as exc:  # noqa: BLE001
            print(f"[tts] generate failed: {exc}", file=sys.stderr)
            self.send_error(500, "tts failed")
            return

        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            tmp_path = Path(tmp.name)
        try:
            _write_wav(tmp_path, samples, rate)
            data = tmp_path.read_bytes()
        finally:
            tmp_path.unlink(missing_ok=True)

        print(
            f"[tts] chars={len(text)} sid={sid} ms={(time.time() - t0) * 1000:.0f} "
            f"bytes={len(data)}",
            file=sys.stderr,
        )
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8092)
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument(
        "--provider",
        default=os.environ.get("COMSTAR_TTS_PROVIDER", "cpu"),
    )
    parser.add_argument(
        "--sid",
        type=int,
        default=int(os.environ.get("COMSTAR_TTS_KOKORO_SID", "0")),
        help="Default Kokoro speaker id (af_heart=0)",
    )
    args = parser.parse_args()

    TtsHandler.model_dir = Path(args.model_dir)
    TtsHandler.threads = max(1, args.threads)
    TtsHandler.provider = args.provider
    TtsHandler.default_sid = max(0, args.sid)
    token = os.environ.get("AGENTIC_SPEECH_TOKEN", "").strip()
    TtsHandler.auth_token = token or None

    if not TtsHandler.model_dir.is_dir():
        print(f"Model dir missing: {TtsHandler.model_dir}", file=sys.stderr)
        return 1

    TtsHandler.load_model()
    server = ThreadingHTTPServer((args.host, args.port), TtsHandler)
    print(
        f"COMSTAR TTS (kokoro) on http://{args.host}:{args.port} "
        f"sid={TtsHandler.default_sid}",
        file=sys.stderr,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.", file=sys.stderr)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
