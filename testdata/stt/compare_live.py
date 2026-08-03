#!/usr/bin/env python3
"""Compare STT engines on golden vs live bridge captures."""
from __future__ import annotations

from pathlib import Path

from faster_whisper import WhisperModel

FILES = {
    "live": Path("/opt/comstar/testdata/stt/live-last.wav"),
    "haydt": Path("/opt/comstar/src/testdata/stt/haydt-20260802-210836.wav"),
}


def main() -> None:
    for size in ("tiny", "base", "tiny.en", "base.en"):
        try:
            model = WhisperModel(size, device="cpu", compute_type="int8")
        except Exception as exc:  # noqa: BLE001
            print(size, "LOAD_FAIL", exc)
            continue
        for name, path in FILES.items():
            if not path.is_file():
                print(size, name, "MISSING")
                continue
            segments, _info = model.transcribe(
                str(path),
                language="en",
                vad_filter=False,
                condition_on_previous_text=False,
                beam_size=5,
                temperature=0.0,
                without_timestamps=True,
            )
            text = "".join(s.text for s in segments).strip()
            print(f"{size:8} {name:5} => {text!r}")


if __name__ == "__main__":
    main()
