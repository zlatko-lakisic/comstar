"""Energy VAD hysteresis — fast speech must not end on soft mid-phrase dips."""

from __future__ import annotations

import math
import struct
import unittest

from vad import VadEngine


def _pcm_rms(rms: float, samples: int = 512) -> bytes:
    """Synthetic int16 mono block at approximately ``rms`` (0..1)."""
    amp = max(0, min(32767, int(rms * 32767 * math.sqrt(2))))
    # Alternating ±amp → RMS ≈ amp/√2 / 32768 ≈ rms when amp = rms*32767*√2
    vals = []
    for i in range(samples):
        vals.append(amp if (i % 2 == 0) else -amp)
    return struct.pack("<" + "h" * samples, *vals)


class EnergyVadHysteresisTest(unittest.TestCase):
    def test_soft_mid_phrase_does_not_end_speech(self) -> None:
        vad = VadEngine(
            silence_ms=400,
            energy_threshold=0.04,
            continue_threshold=0.022,
            min_speech_ms=200,
            start_hold_ms=50,
        )
        # Start with clear speech (need ≥ min_speech_ms before an end can fire).
        for _ in range(12):
            start, end = vad.process(_pcm_rms(0.08))
            if start:
                break
        self.assertTrue(vad._speech)
        for _ in range(8):
            vad.process(_pcm_rms(0.08))

        # Soft frames that would fail the start gate but pass continue.
        for _ in range(3):
            start, end = vad.process(_pcm_rms(0.028))
            self.assertIsNone(end)
            self.assertTrue(vad._speech)

        # True silence ends after silence_ms.
        ended = False
        quiet = struct.pack("<" + "h" * 512, *([0] * 512))
        for _ in range(30):
            _, end = vad.process(quiet)
            if end:
                ended = True
                break
        self.assertTrue(ended)

    def test_idle_noise_does_not_start(self) -> None:
        vad = VadEngine(energy_threshold=0.04, start_hold_ms=50)
        for _ in range(10):
            start, end = vad.process(_pcm_rms(0.02))
            self.assertIsNone(start)
            self.assertIsNone(end)
            self.assertFalse(vad._speech)


if __name__ == "__main__":
    unittest.main()
