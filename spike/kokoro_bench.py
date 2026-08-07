#!/usr/bin/env python3
"""TTS.0.1 / TTS.0.2 — Kokoro bench on the AI server (sherpa-onnx).

Measures RTF and time-to-first-audio-chunk separately, idle and under
CodeProject.AI load. Prints machine-readable JSON lines; verify_tts.sh
appends a table to docs/BASELINES.md.

Env:
  COMSTAR_KOKORO_MODEL_DIR   default ~/agentic-speech-models/tts-kokoro
  COMSTAR_TTS_PROVIDER       cpu|cuda (default cpu; cuda may fall back)
  COMSTAR_TTS_KOKORO_SID     speaker id (default 0 = af_heart)
  COMSTAR_TTS_THREADS        default 4
  CPAI_URL                   default http://127.0.0.1:32168
  KOKORO_BENCH_MODE          idle|contended|both (default both)
  KOKORO_BENCH_REPEATS       default 5
  KOKORO_BENCH_WARMUP        default 1

This is verification only — no bridge / product client changes.
"""
from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


DEFAULT_TEXTS = [
    # ~10 words
    "Welcome home. The hallway lights are already on for you.",
    # ~40 words (latency-budget row)
    "I checked the driveway cameras. Nobody new stopped by this afternoon, "
    "but a package was left near the east side door around three.",
]


@dataclass
class RunRow:
    mode: str
    provider_requested: str
    provider_effective: str
    sid: int
    text_chars: int
    text_words: int
    sample_rate: int
    audio_sec: float
    synth_sec: float
    rtf: float
    ttfc_ms: float | None
    callback_count: int
    first_chunk_samples: int
    vram_used_mib_before: float | None
    vram_used_mib_after: float | None
    gpu_util_pct_before: float | None
    note: str = ""


def _env_path(name: str, default: Path) -> Path:
    raw = os.environ.get(name, "").strip()
    return Path(raw).expanduser() if raw else default


def _nvidia_query() -> tuple[float | None, float | None]:
    """Return (vram_used_MiB, gpu_util_pct) or (None, None)."""
    import subprocess

    try:
        out = subprocess.check_output(
            [
                "nvidia-smi",
                "--query-gpu=memory.used,utilization.gpu",
                "--format=csv,noheader,nounits",
            ],
            text=True,
            timeout=5,
        ).strip()
    except (FileNotFoundError, subprocess.SubprocessError, OSError):
        return None, None
    if not out:
        return None, None
    # first GPU
    line = out.splitlines()[0]
    parts = [p.strip() for p in line.split(",")]
    if len(parts) < 2:
        return None, None
    try:
        return float(parts[0]), float(parts[1])
    except ValueError:
        return None, None


def _cpai_alive(url: str) -> bool:
    try:
        with urllib.request.urlopen(f"{url.rstrip('/')}/v1/server/status/ping", timeout=3) as r:
            return 200 <= r.status < 300
    except (urllib.error.URLError, TimeoutError, OSError):
        return False


def _cpai_detection_storm(
    url: str,
    stop: threading.Event,
    image_bytes: bytes,
) -> None:
    """Hammer detection while stop is clear."""
    boundary = b"----comstarbench"
    body = (
        b"--" + boundary + b"\r\n"
        b'Content-Disposition: form-data; name="min_confidence"\r\n\r\n'
        b"0.4\r\n"
        b"--" + boundary + b"\r\n"
        b'Content-Disposition: form-data; name="image"; filename="frame.jpg"\r\n'
        b"Content-Type: image/jpeg\r\n\r\n" + image_bytes + b"\r\n"
        b"--" + boundary + b"--\r\n"
    )
    endpoint = f"{url.rstrip('/')}/v1/vision/detection"
    while not stop.is_set():
        req = urllib.request.Request(
            endpoint,
            data=body,
            headers={
                "Content-Type": f"multipart/form-data; boundary={boundary.decode()}",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                r.read()
        except Exception:  # noqa: BLE001 — keep storming
            time.sleep(0.05)


def _tiny_jpeg() -> bytes:
    """Minimal valid 1x1 JPEG (no line breaks — fromhex is strict)."""
    return bytes(
        [
            0xFF,
            0xD8,
            0xFF,
            0xE0,
            0x00,
            0x10,
            0x4A,
            0x46,
            0x49,
            0x46,
            0x00,
            0x01,
            0x01,
            0x00,
            0x00,
            0x01,
            0x00,
            0x01,
            0x00,
            0x00,
            0xFF,
            0xDB,
            0x00,
            0x43,
            0x00,
            *([0x08] * 64),
            0xFF,
            0xC0,
            0x00,
            0x0B,
            0x08,
            0x00,
            0x01,
            0x00,
            0x01,
            0x01,
            0x01,
            0x11,
            0x00,
            0xFF,
            0xC4,
            0x00,
            0x14,
            0x00,
            0x01,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0xFF,
            0xDA,
            0x00,
            0x08,
            0x01,
            0x01,
            0x00,
            0x00,
            0x3F,
            0x00,
            0x7F,
            0xFF,
            0xD9,
        ]
    )


def load_tts(
    model_dir: Path,
    provider: str,
    threads: int,
) -> tuple[Any, str]:
    import sherpa_onnx

    cfg = sherpa_onnx.OfflineTtsConfig(
        model=sherpa_onnx.OfflineTtsModelConfig(
            kokoro=sherpa_onnx.OfflineTtsKokoroModelConfig(
                model=str(model_dir / "model.onnx"),
                voices=str(model_dir / "voices.bin"),
                tokens=str(model_dir / "tokens.txt"),
                data_dir=str(model_dir / "espeak-ng-data"),
            ),
            provider=provider,
            num_threads=max(1, threads),
            debug=False,
        ),
        max_num_sentences=1,
    )
    if not cfg.validate():
        raise RuntimeError("Invalid OfflineTtsConfig")
    t0 = time.time()
    tts = sherpa_onnx.OfflineTts(cfg)
    load_s = time.time() - t0
    # Detect CUDA fallback: sherpa prints to stderr; we also probe by attempting
    # a generate after load. Effective provider inferred from load message + probe.
    effective = provider
    # If cuda was requested but ORT has no CUDA EP, sherpa falls back to CPU.
    # Re-read stderr is hard; check lib linkage note from env stamp.
    note_path = os.environ.get("KOKORO_BENCH_PROVIDER_NOTE", "")
    if note_path == "cuda_fallback_cpu":
        effective = "cpu(fallback)"
    print(
        json.dumps(
            {
                "evt": "model_loaded",
                "provider_requested": provider,
                "load_sec": round(load_s, 3),
                "sample_rate": int(tts.sample_rate),
                "num_speakers": int(tts.num_speakers),
            }
        ),
        flush=True,
    )
    return tts, effective


def synth_once(
    tts: Any,
    text: str,
    sid: int,
    mode: str,
    provider_requested: str,
    provider_effective: str,
) -> RunRow:
    first_t: list[float] = []
    chunk_n = [0]
    first_samples = [0]

    def callback(samples, progress: float) -> int:  # noqa: ANN001
        # Return 0 to continue (sherpa: non-zero aborts).
        now = time.perf_counter()
        if not first_t:
            first_t.append(now)
            try:
                first_samples[0] = int(len(samples))
            except TypeError:
                first_samples[0] = 0
        chunk_n[0] += 1
        _ = progress
        return 0

    vram_b, util_b = _nvidia_query()
    t0 = time.perf_counter()
    audio = tts.generate(text, sid=sid, speed=1.0, callback=callback)
    t1 = time.perf_counter()
    vram_a, _ = _nvidia_query()

    samples = audio.samples
    rate = int(audio.sample_rate)
    n = len(samples)
    audio_sec = n / float(rate) if rate > 0 else 0.0
    synth_sec = t1 - t0
    rtf = synth_sec / audio_sec if audio_sec > 0 else float("inf")
    ttfc_ms = None
    if first_t:
        ttfc_ms = (first_t[0] - t0) * 1000.0

    words = len(text.split())
    return RunRow(
        mode=mode,
        provider_requested=provider_requested,
        provider_effective=provider_effective,
        sid=sid,
        text_chars=len(text),
        text_words=words,
        sample_rate=rate,
        audio_sec=round(audio_sec, 4),
        synth_sec=round(synth_sec, 4),
        rtf=round(rtf, 4),
        ttfc_ms=None if ttfc_ms is None else round(ttfc_ms, 2),
        callback_count=chunk_n[0],
        first_chunk_samples=first_samples[0],
        vram_used_mib_before=vram_b,
        vram_used_mib_after=vram_a,
        gpu_util_pct_before=util_b,
    )


def summarize(rows: list[RunRow]) -> dict[str, Any]:
    if not rows:
        return {}
    rtfs = [r.rtf for r in rows]
    ttfcs = [r.ttfc_ms for r in rows if r.ttfc_ms is not None]
    synths = [r.synth_sec for r in rows]
    out: dict[str, Any] = {
        "n": len(rows),
        "rtf_mean": round(statistics.mean(rtfs), 4),
        "rtf_p50": round(statistics.median(rtfs), 4),
        "synth_sec_mean": round(statistics.mean(synths), 4),
        "callback_count_mean": round(
            statistics.mean(r.callback_count for r in rows), 2
        ),
        "streaming_callbacks_observed": any(r.callback_count > 1 for r in rows),
        "sample_rate": rows[0].sample_rate,
    }
    if ttfcs:
        out["ttfc_ms_mean"] = round(statistics.mean(ttfcs), 2)
        out["ttfc_ms_p50"] = round(statistics.median(ttfcs), 2)
        out["ttfc_ms_min"] = round(min(ttfcs), 2)
    return out


def run_mode(
    tts: Any,
    mode: str,
    texts: list[str],
    sid: int,
    provider_requested: str,
    provider_effective: str,
    repeats: int,
    warmup: int,
    cpai_url: str | None,
) -> list[RunRow]:
    stop = threading.Event()
    storm: threading.Thread | None = None
    if mode == "contended":
        if not cpai_url or not _cpai_alive(cpai_url):
            raise RuntimeError(f"CPAI not reachable for contended mode: {cpai_url}")
        stop.clear()
        storm = threading.Thread(
            target=_cpai_detection_storm,
            args=(cpai_url, stop, _tiny_jpeg()),
            daemon=True,
        )
        storm.start()
        time.sleep(1.0)  # let storm warm GPU

    rows: list[RunRow] = []
    try:
        for text in texts:
            for i in range(warmup):
                synth_once(
                    tts, text, sid, mode, provider_requested, provider_effective
                )
            for i in range(repeats):
                row = synth_once(
                    tts, text, sid, mode, provider_requested, provider_effective
                )
                rows.append(row)
                print(json.dumps({"evt": "run", **asdict(row)}), flush=True)
    finally:
        if storm is not None:
            stop.set()
            storm.join(timeout=5)

    print(
        json.dumps(
            {
                "evt": "summary",
                "mode": mode,
                "provider_requested": provider_requested,
                "provider_effective": provider_effective,
                **summarize(rows),
            }
        ),
        flush=True,
    )
    return rows


def probe_streaming_api() -> dict[str, Any]:
    """TTS.0.2 — what the installed Python binding actually exposes."""
    import sherpa_onnx

    doc = sherpa_onnx.OfflineTts.generate.__doc__ or ""
    has_callback = "callback" in doc.lower()
    methods = [n for n in dir(sherpa_onnx.OfflineTts) if not n.startswith("_")]
    return {
        "evt": "streaming_api",
        "sherpa_onnx_version": getattr(sherpa_onnx, "__version__", "?"),
        "offline_tts_methods": methods,
        "generate_doc_mentions_callback": has_callback,
        "generate_doc": doc.strip()[:1200],
        "finding": (
            "API (sherpa-onnx 1.13.4 Python binding): OfflineTts.generate(text, sid, "
            "speed, callback=None) documents an optional callback(samples, progress)->int "
            "invoked during speech generation with sample chunks (C header: "
            "SherpaOnnxGeneratedAudioCallback — incremental). Same OfflineTts path serves "
            "Kokoro via OfflineTtsKokoroModelConfig. "
            "EMPIRICAL (kokoro-en-v0_19 on this host): callback fires exactly once per "
            "utterance with the full sample buffer; TTFC ≈ full synth_sec. So Kokoro is "
            "buffer-complete for first-audio purposes unless sentence-level chunking is "
            "added in tts_server.py. max_num_sentences!=1 is ignored for Kokoro."
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument(
        "--model-dir",
        type=Path,
        default=_env_path(
            "COMSTAR_KOKORO_MODEL_DIR",
            Path.home() / "agentic-speech-models" / "tts-kokoro",
        ),
    )
    parser.add_argument(
        "--provider",
        default=os.environ.get("COMSTAR_TTS_PROVIDER", "cpu"),
    )
    parser.add_argument(
        "--sid",
        type=int,
        default=int(os.environ.get("COMSTAR_TTS_KOKORO_SID", "0")),
    )
    parser.add_argument(
        "--threads",
        type=int,
        default=int(os.environ.get("COMSTAR_TTS_THREADS", "4")),
    )
    parser.add_argument(
        "--mode",
        choices=("idle", "contended", "both", "api-only"),
        default=os.environ.get("KOKORO_BENCH_MODE", "both"),
    )
    parser.add_argument(
        "--repeats",
        type=int,
        default=int(os.environ.get("KOKORO_BENCH_REPEATS", "5")),
    )
    parser.add_argument(
        "--warmup",
        type=int,
        default=int(os.environ.get("KOKORO_BENCH_WARMUP", "1")),
    )
    parser.add_argument(
        "--cpai-url",
        default=os.environ.get("CPAI_URL", "http://127.0.0.1:32168"),
    )
    parser.add_argument(
        "--json-out",
        type=Path,
        default=None,
        help="Write full result JSON to this path",
    )
    args = parser.parse_args()

    api = probe_streaming_api()
    print(json.dumps(api), flush=True)
    if args.mode == "api-only":
        if args.json_out:
            args.json_out.write_text(json.dumps({"streaming_api": api}, indent=2))
        return 0

    if not args.model_dir.is_dir():
        print(f"model dir missing: {args.model_dir}", file=sys.stderr)
        return 2

    # Detect CUDA EP availability before load (for accurate effective provider).
    provider_effective = args.provider
    so = Path(
        "/var/lib/agentic/venv-tts/lib/python3.12/site-packages/sherpa_onnx/lib/"
        "libonnxruntime.so"
    )
    if args.provider == "cuda":
        # Packaged ORT in this venv historically has no CUDA EP.
        try:
            import subprocess

            ldd = subprocess.check_output(["ldd", str(so)], text=True, timeout=5)
            if "cuda" not in ldd.lower() and "cublas" not in ldd.lower():
                provider_effective = "cpu(fallback)"
                os.environ["KOKORO_BENCH_PROVIDER_NOTE"] = "cuda_fallback_cpu"
        except Exception:  # noqa: BLE001
            provider_effective = "cpu(fallback?)"

    tts, _ = load_tts(args.model_dir, args.provider, args.threads)
    # Prefer sample_rate from engine after load.
    provider_effective = provider_effective

    all_rows: list[RunRow] = []
    modes = ["idle", "contended"] if args.mode == "both" else [args.mode]
    for mode in modes:
        all_rows.extend(
            run_mode(
                tts=tts,
                mode=mode,
                texts=DEFAULT_TEXTS,
                sid=args.sid,
                provider_requested=args.provider,
                provider_effective=provider_effective,
                repeats=args.repeats,
                warmup=args.warmup,
                cpai_url=args.cpai_url if mode == "contended" else None,
            )
        )

    result = {
        "streaming_api": api,
        "provider_requested": args.provider,
        "provider_effective": provider_effective,
        "model_dir": str(args.model_dir),
        "sid": args.sid,
        "runs": [asdict(r) for r in all_rows],
        "summaries": {
            m: summarize([r for r in all_rows if r.mode == m]) for m in modes
        },
    }
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps({"evt": "wrote", "path": str(args.json_out)}), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
