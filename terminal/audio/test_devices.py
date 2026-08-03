"""Unit tests for mic/speaker env device resolution (no hardware required)."""

from __future__ import annotations

import os
import unittest
from unittest import mock

import devices


class DevicesEnvTest(unittest.TestCase):
    def test_mic_source_prefers_comstar_mic_source(self) -> None:
        with mock.patch.dict(
            os.environ,
            {"COMSTAR_MIC_SOURCE": "C525", "COMSTAR_MIC_DEVICE": "9"},
            clear=False,
        ):
            self.assertEqual(devices.mic_source_spec(), "C525")

    def test_speaker_source_aliases(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertIsNone(devices.speaker_source_spec())
        with mock.patch.dict(
            os.environ, {"COMSTAR_SPEAKER_SINK": "comstar_hdmi"}, clear=True
        ):
            self.assertEqual(devices.speaker_source_spec(), "comstar_hdmi")

    def test_resolve_empty_is_default(self) -> None:
        self.assertIsNone(devices.resolve_sounddevice_input(None))
        self.assertIsNone(devices.resolve_sounddevice_input("  "))

    def test_resolve_numeric_index(self) -> None:
        self.assertEqual(devices.resolve_sounddevice_input("3"), 3)


if __name__ == "__main__":
    unittest.main()
