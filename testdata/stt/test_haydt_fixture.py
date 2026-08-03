"""Ground-truth fixture for the C525 'How are you doing today' capture."""

from __future__ import annotations

import json
import unittest
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent
STAMPED = ROOT / "haydt-20260802-210836.wav"
STAMPED_META = ROOT / "haydt-20260802-210836.json"
LATEST = ROOT / "haydt-latest.wav"
LATEST_META = ROOT / "haydt-latest.json"
EXPECTED = "How are you doing today"


class HaydtFixtureTest(unittest.TestCase):
    def test_stamped_meta_transcript(self) -> None:
        meta = json.loads(STAMPED_META.read_text())
        self.assertEqual(meta["transcript"], EXPECTED)
        self.assertTrue(STAMPED.is_file(), f"missing {STAMPED}")

    def test_latest_meta_transcript(self) -> None:
        meta = json.loads(LATEST_META.read_text())
        self.assertEqual(meta["transcript"], EXPECTED)
        self.assertTrue(LATEST.is_file(), f"missing {LATEST}")

    def test_wav_is_16k_mono_pcm(self) -> None:
        with wave.open(str(STAMPED), "rb") as w:
            self.assertEqual(w.getnchannels(), 1)
            self.assertEqual(w.getsampwidth(), 2)
            self.assertEqual(w.getframerate(), 16000)
            self.assertGreater(w.getnframes(), 0)


if __name__ == "__main__":
    unittest.main()
