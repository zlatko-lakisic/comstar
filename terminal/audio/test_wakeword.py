"""Wake word refractory unit tests."""

from __future__ import annotations

import time
import unittest

from wakeword import WakeWordEngine


class WakeTests(unittest.TestCase):
    def test_missing_model_never_fires(self) -> None:
        eng = WakeWordEngine("/nonexistent/hey_comstar.onnx")
        self.assertFalse(eng.available)
        self.assertIsNone(eng.process(b"\x00" * 3200))

    def test_refractory_blocks_double_fire(self) -> None:
        eng = WakeWordEngine("/nonexistent/x.onnx", refractory_s=2.0)
        eng.mark_fired()
        # Force-path uses mark_fired; process still None without model,
        # but mark_fired timestamp is set — verify via private clock delta.
        self.assertGreater(eng._last_fire_monotonic, 0)
        self.assertFalse(eng.can_fire())
        t0 = eng._last_fire_monotonic
        time.sleep(0.05)
        eng.mark_fired()
        self.assertGreater(eng._last_fire_monotonic, t0)

    def test_can_fire_after_refractory(self) -> None:
        eng = WakeWordEngine("/nonexistent/x.onnx", refractory_s=0.05)
        self.assertTrue(eng.can_fire())
        eng.mark_fired()
        self.assertFalse(eng.can_fire())
        time.sleep(0.06)
        self.assertTrue(eng.can_fire())


if __name__ == "__main__":
    unittest.main()
