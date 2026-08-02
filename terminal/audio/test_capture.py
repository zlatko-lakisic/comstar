"""Tests for in-memory ring buffer (no external deps)."""

from __future__ import annotations

import struct
import unittest


class RingBuffer:
    """Minimal copy of capture.RingBuffer for unit tests without numpy."""

    def __init__(self, sample_rate: int = 16000, seconds: float = 3.0) -> None:
        self.sample_rate = sample_rate
        self.max_bytes = int(sample_rate * seconds) * 2
        self._data = bytearray()
        self._total = 0

    def write(self, pcm: bytes) -> None:
        if not pcm:
            return
        self._data.extend(pcm)
        self._total += len(pcm)
        while self._total > self.max_bytes and self._data:
            drop = min(len(self._data), self._total - self.max_bytes)
            del self._data[:drop]
            self._total -= drop

    def read_all(self) -> bytes:
        return bytes(self._data)

    def clear(self) -> None:
        self._data.clear()
        self._total = 0

    @property
    def duration_ms(self) -> int:
        return int(self._total / 2 / self.sample_rate * 1000)


class RingBufferTest(unittest.TestCase):
    def test_drops_oldest_past_capacity(self) -> None:
        ring = RingBuffer(sample_rate=100, seconds=1.0)
        ring.write(bytes([0] * 100))
        ring.write(bytes([1] * 100))
        ring.write(bytes([2] * 100))
        data = ring.read_all()
        self.assertEqual(len(data), 200)

    def test_clear(self) -> None:
        ring = RingBuffer(sample_rate=16000, seconds=3.0)
        ring.write(struct.pack("<h", 0) * 1600)
        ring.clear()
        self.assertEqual(ring.read_all(), b"")
        self.assertEqual(ring.duration_ms, 0)


if __name__ == "__main__":
    unittest.main()
