"""Unit tests for SoftAgc."""

from __future__ import annotations

import unittest

import numpy as np

from agc import SoftAgc, agc_from_env


class SoftAgcTest(unittest.TestCase):
    def test_reduces_hot_speech(self) -> None:
        agc = SoftAgc(target_rms=0.08, max_gain=1.0, min_gain=0.2, attack=1.0, release=1.0)
        # Loud block ~0.5 RMS
        loud = (np.sin(np.linspace(0, 40 * np.pi, 1600)) * 20000).astype(np.int16)
        out = agc.process(loud)
        in_rms = float(np.sqrt(np.mean(np.square(loud.astype(np.float32) / 32768.0))))
        out_rms = float(np.sqrt(np.mean(np.square(out.astype(np.float32) / 32768.0))))
        self.assertLess(out_rms, in_rms)
        self.assertLess(agc.gain, 1.0)

    def test_does_not_boost_silence(self) -> None:
        agc = SoftAgc(target_rms=0.08, noise_floor=0.012, attack=1.0, release=1.0)
        silence = np.zeros(1600, dtype=np.int16)
        agc.process(silence)
        self.assertLessEqual(agc.gain, 1.05)

    def test_agc_from_env_default_on(self) -> None:
        import os

        os.environ.pop("COMSTAR_MIC_AGC", None)
        self.assertIsNotNone(agc_from_env())
        os.environ["COMSTAR_MIC_AGC"] = "0"
        self.assertIsNone(agc_from_env())
        os.environ.pop("COMSTAR_MIC_AGC", None)


if __name__ == "__main__":
    unittest.main()
