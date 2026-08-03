"""Tests for in-memory ring buffer (no external deps)."""

from __future__ import annotations

import struct
import unittest

import numpy as np

from capture import RingBuffer


class RingBufferTest(unittest.TestCase):
    def test_drops_oldest_past_capacity(self) -> None:
        ring = RingBuffer(sample_rate=100, seconds=1.0)
        ring.write(np.zeros(100, dtype=np.int16))
        ring.write(np.ones(100, dtype=np.int16))
        ring.write(np.full(100, 2, dtype=np.int16))
        data = ring.read_all()
        self.assertEqual(len(data), 200)  # 100 samples * 2 bytes (1s capacity)

    def test_clear(self) -> None:
        ring = RingBuffer(sample_rate=16000, seconds=3.0)
        ring.write(np.zeros(1600, dtype=np.int16))
        ring.clear()
        self.assertEqual(ring.read_all(), b"")
        self.assertEqual(ring.duration_ms, 0)
        # Cursor stays high so listeners do not replay wiped audio.
        self.assertEqual(ring.written_samples, 1600)

    def test_read_since_survives_wrap(self) -> None:
        # 1 second capacity @ 100 Hz = 100 samples.
        ring = RingBuffer(sample_rate=100, seconds=1.0)
        cursor = 0
        collected = bytearray()

        # Write 5 seconds of unique sample values while reading continuously.
        for second in range(5):
            block = np.arange(second * 100, (second + 1) * 100, dtype=np.int16)
            ring.write(block)
            data, cursor = ring.read_since(cursor)
            collected.extend(data)

        # Must have received every sample 0..499 despite the 1s ring.
        samples = struct.unpack("<" + "h" * (len(collected) // 2), collected)
        self.assertEqual(list(samples), list(range(500)))

    def test_read_since_skips_unread_drop(self) -> None:
        ring = RingBuffer(sample_rate=100, seconds=1.0)
        ring.write(np.arange(0, 100, dtype=np.int16))
        # Never read — overwrite entire ring.
        ring.write(np.arange(100, 200, dtype=np.int16))
        data, cursor = ring.read_since(0)
        samples = struct.unpack("<" + "h" * (len(data) // 2), data)
        self.assertEqual(list(samples), list(range(100, 200)))
        self.assertEqual(cursor, 200)


if __name__ == "__main__":
    unittest.main()
