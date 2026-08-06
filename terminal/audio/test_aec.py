"""Unit tests for AEC helper (no Speex / numpy required)."""

from __future__ import annotations

import os
import unittest
from unittest.mock import patch

from aec import aec_requested, build_aec


class AecTests(unittest.TestCase):
    def test_aec_requested_env(self) -> None:
        with patch.dict(os.environ, {"COMSTAR_AEC": "1"}, clear=False):
            self.assertTrue(aec_requested())
        with patch.dict(os.environ, {"COMSTAR_AEC": "0"}, clear=False):
            self.assertFalse(aec_requested())

    def test_build_aec_off(self) -> None:
        with patch.dict(os.environ, {"COMSTAR_AEC": ""}, clear=False):
            self.assertIsNone(build_aec())


if __name__ == "__main__":
    unittest.main()
