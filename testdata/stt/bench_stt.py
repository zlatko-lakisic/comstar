"""STT-only evaluation: golden file + labeled LIVE bridge captures.

IMPORTANT — what “correct” testing means
----------------------------------------
Replaying one WAV ten times proves *determinism*, not product accuracy.
COMSTAR must be scored on audio that went through the real path:

  mic → comstar-audio → bridge PCM buffer → HttpSttClient WAV → STT

Fixtures
--------
Each ``*.json`` next to a ``*.wav`` must include::

  {
    "file": "….wav",
    "transcript": "ground truth spoken words",
    "source": "bridge" | "parecord" | "synthetic",
    "path": "audio→bridge→stt"   // required for live scoring
  }

``source=parecord`` / synthetic fixtures are allowed for smoke checks but
**do not count toward the live 10/10 gate**.

Usage::

  # Offline metadata tests
  python3 -m unittest discover -s testdata/stt -p 'test_*.py'

  # Live gate (needs Pi models + labeled bridge fixtures)
  COMSTAR_STT_BENCH=1 python3 -m testdata.stt.bench_stt --trials 1 --require-live 10
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Callable


ROOT = Path(__file__).resolve().parent


def normalize_transcript(text: str) -> str:
    t = (text or "").strip().lower()
    t = t.replace("’", "'").replace("‘", "'")
    t = re.sub(r"[^\w\s']", " ", t)
    t = re.sub(r"\s+", " ", t).strip()
    return t


def transcripts_match(got: str, expected: str) -> bool:
    g = normalize_transcript(got)
    e = normalize_transcript(expected)
    if not e:
        return not g
    if g == e:
        return True
    if g.startswith(e) and len(g) - len(e) <= 12:
        return True
    return False


@dataclass(frozen=True)
class Fixture:
    wav: Path
    transcript: str
    name: str
    source: str
    path: str

    @property
    def is_live_bridge(self) -> bool:
        return self.source == "bridge" and self.path == "audio→bridge→stt"

    @classmethod
    def load(cls, meta_path: Path) -> Fixture:
        meta = json.loads(meta_path.read_text())
        wav_name = meta.get("file") or meta_path.with_suffix(".wav").name
        return cls(
            wav=meta_path.parent / wav_name,
            transcript=meta["transcript"],
            name=meta_path.stem,
            source=str(meta.get("source", "unknown")),
            path=str(meta.get("path", "")),
        )


def load_fixtures(*, live_only: bool = False) -> list[Fixture]:
    fixtures: list[Fixture] = []
    for meta in sorted(ROOT.glob("*.json")):
        if meta.name.startswith("bench_results"):
            continue
        if "compare" in meta.name:
            continue
        try:
            fix = Fixture.load(meta)
        except (KeyError, json.JSONDecodeError):
            continue
        if not fix.wav.is_file():
            continue
        if live_only and not fix.is_live_bridge:
            continue
        fixtures.append(fix)
    return fixtures


def _load_wav_float32(path: Path) -> tuple[object, int]:
    import numpy as np

    with wave.open(str(path), "rb") as w:
        rate = w.getframerate()
        ch = w.getnchannels()
        sw = w.getsampwidth()
        raw = w.readframes(w.getnframes())
    if sw != 2:
        raise ValueError(f"unsupported sampwidth={sw} in {path}")
    samples = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    if ch > 1:
        samples = samples.reshape(-1, ch).mean(axis=1)
    return samples, rate


EngineFn = Callable[[Path], str]


def engine_faster_whisper(model_size: str, **opts: object) -> EngineFn:
    label_opts = dict(opts)

    def _run(path: Path) -> str:
        from faster_whisper import WhisperModel

        if not hasattr(engine_faster_whisper, "_models"):
            engine_faster_whisper._models = {}  # type: ignore[attr-defined]
        cache = engine_faster_whisper._models  # type: ignore[attr-defined]
        if model_size not in cache:
            cache[model_size] = WhisperModel(
                model_size, device="cpu", compute_type="int8"
            )
        model = cache[model_size]
        segments, _info = model.transcribe(
            str(path),
            language=str(opts.get("language", "en")),
            vad_filter=bool(opts.get("vad_filter", False)),
            condition_on_previous_text=bool(
                opts.get("condition_on_previous_text", False)
            ),
            beam_size=int(opts.get("beam_size", 5)),
            best_of=int(opts.get("best_of", 5)),
            temperature=float(opts.get("temperature", 0.0)),
            without_timestamps=True,
        )
        return "".join(s.text for s in segments).strip()

    _run.label = (  # type: ignore[attr-defined]
        f"faster_whisper:{model_size}:{json.dumps(label_opts, sort_keys=True)}"
    )
    return _run


def engine_moonshine(model_dir: Path) -> EngineFn:
    def _run(path: Path) -> str:
        import sherpa_onnx

        if not hasattr(engine_moonshine, "_recs"):
            engine_moonshine._recs = {}  # type: ignore[attr-defined]
        cache = engine_moonshine._recs  # type: ignore[attr-defined]
        key = str(model_dir)
        if key not in cache:
            cache[key] = sherpa_onnx.OfflineRecognizer.from_moonshine(
                preprocessor=str(model_dir / "preprocess.onnx"),
                encoder=str(model_dir / "encode.int8.onnx"),
                uncached_decoder=str(model_dir / "uncached_decode.int8.onnx"),
                cached_decoder=str(model_dir / "cached_decode.int8.onnx"),
                tokens=str(model_dir / "tokens.txt"),
                num_threads=2,
                provider="cpu",
            )
        rec = cache[key]
        samples, rate = _load_wav_float32(path)
        stream = rec.create_stream()
        stream.accept_waveform(rate, samples)
        rec.decode_stream(stream)
        return (stream.result.text or "").strip()

    _run.label = f"moonshine:{model_dir.name}"  # type: ignore[attr-defined]
    return _run


def engine_http(base_url: str) -> EngineFn:
    def _run(path: Path) -> str:
        import subprocess

        out = subprocess.check_output(
            [
                "curl",
                "-sS",
                "-F",
                f"file=@{path}",
                "-F",
                "model=whisper-1",
                f"{base_url.rstrip('/')}/v1/audio/transcriptions",
            ],
            text=True,
        )
        return str(json.loads(out).get("text") or "").strip()

    _run.label = f"http:{base_url}"  # type: ignore[attr-defined]
    return _run


def discover_engines(names: list[str] | None = None) -> list[EngineFn]:
    wanted = set(names) if names else None
    engines: list[EngineFn] = []

    def add(name: str, fn: EngineFn) -> None:
        if wanted is None or name in wanted:
            engines.append(fn)

    for size in ("tiny", "base", "tiny.en", "base.en"):
        add(
            f"fw_{size.replace('.', '_')}",
            engine_faster_whisper(size, vad_filter=False, beam_size=5),
        )

    import os

    sherpa_root = Path(
        os.environ.get("COMSTAR_SHERPA_ROOT", "/opt/comstar/models/sherpa")
    )
    for key, dirname in (
        ("moonshine_tiny", "stt-moonshine-tiny"),
        ("moonshine_base", "stt-moonshine-base"),
    ):
        d = sherpa_root / dirname
        if d.is_dir():
            add(key, engine_moonshine(d.resolve()))

    http_url = os.environ.get("COMSTAR_STT_URL", "http://127.0.0.1:8090")
    add("http_local", engine_http(http_url))
    return engines


@dataclass
class TrialResult:
    engine: str
    fixture: str
    source: str
    live: bool
    trial: int
    text: str
    ok: bool
    ms: float


def run_trials(
    engines: list[EngineFn],
    fixtures: list[Fixture],
    trials: int,
) -> list[TrialResult]:
    results: list[TrialResult] = []
    for engine in engines:
        label = getattr(engine, "label", repr(engine))
        try:
            _ = engine(fixtures[0].wav)
        except Exception as exc:  # noqa: BLE001
            print(f"[skip] {label}: {exc}", file=sys.stderr)
            continue
        for fix in fixtures:
            for i in range(1, trials + 1):
                t0 = time.time()
                try:
                    text = engine(fix.wav)
                    err = None
                except Exception as exc:  # noqa: BLE001
                    text = ""
                    err = str(exc)
                ms = (time.time() - t0) * 1000
                ok = transcripts_match(text, fix.transcript)
                results.append(
                    TrialResult(
                        engine=label,
                        fixture=fix.name,
                        source=fix.source,
                        live=fix.is_live_bridge,
                        trial=i,
                        text=text if err is None else f"ERROR:{err}",
                        ok=ok,
                        ms=ms,
                    )
                )
                kind = "LIVE" if fix.is_live_bridge else fix.source
                mark = "OK" if ok else "FAIL"
                print(
                    f"[{mark}/{kind}] {label} {fix.name} #{i}/{trials} "
                    f"{ms:.0f}ms expected={fix.transcript!r} got={text!r}",
                    flush=True,
                )
    return results


def summarize(results: list[TrialResult], trials: int) -> list[dict]:
    from collections import defaultdict

    groups: dict[tuple[str, str], list[TrialResult]] = defaultdict(list)
    for r in results:
        groups[(r.engine, r.fixture)].append(r)

    rows: list[dict] = []
    for (engine, fixture), items in sorted(groups.items()):
        ok = sum(1 for x in items if x.ok)
        live = items[0].live if items else False
        rows.append(
            {
                "engine": engine,
                "fixture": fixture,
                "source": items[0].source if items else "",
                "live": live,
                "ok": ok,
                "trials": len(items),
                "perfect": ok == len(items) and len(items) == trials,
                "avg_ms": round(sum(x.ms for x in items) / max(len(items), 1), 1),
                "texts": sorted({x.text for x in items}),
            }
        )
    return rows


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trials", type=int, default=1)
    parser.add_argument("--engines", default="")
    parser.add_argument(
        "--require-live",
        type=int,
        default=0,
        help="Require N distinct live bridge fixtures all perfect for a winner",
    )
    parser.add_argument("--live-only", action="store_true")
    parser.add_argument("--out", type=Path, default=ROOT / "bench_results.json")
    args = parser.parse_args(argv)

    fixtures = load_fixtures(live_only=args.live_only)
    if not fixtures:
        print("No fixtures found", file=sys.stderr)
        return 2

    live = [f for f in fixtures if f.is_live_bridge]
    print(
        f"fixtures total={len(fixtures)} live_bridge={len(live)} "
        f"require_live={args.require_live}"
    )
    for f in fixtures:
        tag = "LIVE" if f.is_live_bridge else f.source
        print(f"  [{tag}] {f.name}: {f.transcript!r}")

    if args.require_live and len(live) < args.require_live:
        print(
            f"Need {args.require_live} labeled LIVE bridge fixtures; have {len(live)}. "
            "Capture via COMSTAR Listening, save WAV+JSON with "
            'source=bridge path=\"audio→bridge→stt\".',
            file=sys.stderr,
        )
        return 3

    names = [x.strip() for x in args.engines.split(",") if x.strip()] or None
    engines = discover_engines(names)
    if not engines:
        print("No engines discovered", file=sys.stderr)
        return 2

    score_fixtures = live if args.require_live else fixtures
    results = run_trials(engines, score_fixtures, args.trials)
    rows = summarize(results, args.trials)

    winners: list[dict] = []
    if args.require_live:
        # Engine must be perfect on every live fixture (trials each).
        by_engine: dict[str, list[dict]] = {}
        for r in rows:
            by_engine.setdefault(r["engine"], []).append(r)
        for engine, erows in by_engine.items():
            if len(erows) < args.require_live:
                continue
            if all(r["perfect"] for r in erows):
                winners.append(
                    {
                        "engine": engine,
                        "live_fixtures": len(erows),
                        "avg_ms": round(
                            sum(r["avg_ms"] for r in erows) / len(erows), 1
                        ),
                    }
                )
    else:
        winners = [r for r in rows if r["perfect"]]

    payload = {
        "trials": args.trials,
        "require_live": args.require_live,
        "fixtures": [
            {
                "name": f.name,
                "source": f.source,
                "live": f.is_live_bridge,
                "transcript": f.transcript,
            }
            for f in score_fixtures
        ],
        "results": rows,
        "winners": winners,
        "note": (
            "Parecord/golden-only perfect scores are NOT a live pass. "
            "Use --require-live N with labeled bridge captures."
        ),
    }
    args.out.write_text(json.dumps(payload, indent=2) + "\n")

    print("\n=== summary ===")
    for r in rows:
        flag = "PASS" if r["perfect"] else "----"
        live_flag = "LIVE" if r["live"] else r["source"]
        print(
            f"{flag} [{live_flag}] {r['ok']}/{r['trials']} {r['avg_ms']:.0f}ms "
            f"{r['engine']} expected_fixture={r['fixture']} texts={r['texts']}"
        )
    print(f"wrote {args.out}")

    if winners:
        print("\nWinners:")
        for w in winners:
            print(f"  {w}")
        return 0

    print("\nNo engine passed the gate.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
