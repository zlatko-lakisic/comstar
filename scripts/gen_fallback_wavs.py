#!/usr/bin/env python3
"""Generate short offline fallback WAVs for SpeakFallback (M6.4)."""

from __future__ import annotations

import math
import struct
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets" / "fallback"
SAMPLE_RATE = 22050


def write_tone(path: Path, *, freq: float, duration_ms: int, amp: float = 0.25) -> None:
    n = SAMPLE_RATE * duration_ms // 1000
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        frames = bytearray()
        for i in range(n):
            # Simple envelope to avoid clicks.
            env = min(1.0, i / 200.0, (n - i) / 400.0)
            sample = int(amp * env * 32767 * math.sin(2 * math.pi * freq * i / SAMPLE_RATE))
            frames.extend(struct.pack("<h", sample))
        w.writeframes(frames)


def main() -> None:
    write_tone(OUT / "sorry.wav", freq=440.0, duration_ms=700)
    write_tone(OUT / "offline.wav", freq=330.0, duration_ms=900)
    write_tone(OUT / "error.wav", freq=220.0, duration_ms=500)
    print(f"Wrote fallback WAVs to {OUT}")


if __name__ == "__main__":
    main()
