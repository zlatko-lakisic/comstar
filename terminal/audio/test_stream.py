"""Unit tests for PCM streamer pre-roll and maxMs."""

from __future__ import annotations

import asyncio
import unittest

import numpy as np

from capture import RingBuffer
from stream import FRAME_BYTES, PRE_ROLL_BYTES, PcmStreamer


class FakeCapture:
    """Append-only capture used by legacy streamer tests."""

    def __init__(self, data: bytes) -> None:
        self._data = bytearray(data)

    def snapshot(self) -> bytes:
        return bytes(self._data)

    def clear_ring(self) -> None:
        self._data = bytearray()

    def append(self, data: bytes) -> None:
        self._data.extend(data)


class RingCapture:
    """Real ring-backed capture — exercises wrap-safe streaming."""

    def __init__(self, sample_rate: int = 16000, seconds: float = 3.0) -> None:
        self.ring = RingBuffer(sample_rate=sample_rate, seconds=seconds)

    def write_samples(self, samples: np.ndarray) -> None:
        self.ring.write(samples)

    def snapshot(self) -> bytes:
        return self.ring.read_all()

    def read_since(self, sample_offset: int) -> tuple[bytes, int]:
        return self.ring.read_since(sample_offset)

    @property
    def written_samples(self) -> int:
        return self.ring.written_samples

    def clear_ring(self) -> None:
        self.ring.clear()


class StreamTests(unittest.IsolatedAsyncioTestCase):
    async def test_pre_roll_preserved(self) -> None:
        ring = bytes([1, 2]) * (PRE_ROLL_BYTES // 2 + FRAME_BYTES)
        sent: list[bytes] = []
        envelopes: list[tuple[str, dict]] = []

        async def send_binary(data: bytes) -> None:
            sent.append(data)

        async def send_envelope(t: str, d: dict, _tid: str | None = None) -> None:
            envelopes.append((t, d))

        streamer = PcmStreamer(
            capture=FakeCapture(ring),
            send_binary=send_binary,
            send_envelope=send_envelope,
            max_ms=FRAME_BYTES,  # stop quickly
        )
        await streamer.start("t1", max_ms=320)
        await asyncio.sleep(0.05)
        await streamer.stop()
        self.assertTrue(any(t == "audio.begin" for t, _ in envelopes))
        self.assertTrue(any(t == "audio.end" for t, _ in envelopes))
        self.assertGreaterEqual(len(sent), 1)
        self.assertNotEqual(sent[0], b"\x00" * FRAME_BYTES)

    async def test_max_ms_stops(self) -> None:
        buf = FakeCapture(b"\x00" * (FRAME_BYTES * 20))
        frames = 0

        async def send_binary(_data: bytes) -> None:
            nonlocal frames
            frames += 1

        async def send_envelope(_t: str, _d: dict, _tid: str | None = None) -> None:
            return None

        streamer = PcmStreamer(
            capture=buf,
            send_binary=send_binary,
            send_envelope=send_envelope,
        )
        await streamer.start("t2", max_ms=640)  # two frames
        for _ in range(30):
            if not streamer.active:
                break
            await asyncio.sleep(0.02)
        await streamer.stop()
        self.assertLessEqual(frames, 3)

    async def test_streams_past_ring_capacity(self) -> None:
        """Regression: old offset-into-snapshot starved after ~3s ring wrap."""
        capture = RingCapture(sample_rate=16000, seconds=1.0)  # tiny ring
        sent: list[bytes] = []

        async def send_binary(data: bytes) -> None:
            sent.append(data)

        async def send_envelope(_t: str, _d: dict, _tid: str | None = None) -> None:
            return None

        streamer = PcmStreamer(
            capture=capture,
            send_binary=send_binary,
            send_envelope=send_envelope,
        )
        await streamer.start("t3", max_ms=5000, pre_roll_ms=0, clear_ring=True)

        # Feed 4 seconds of audio in 100ms blocks while streamer runs.
        for i in range(40):
            block = np.full(1600, i, dtype=np.int16)  # 100ms @ 16kHz
            capture.write_samples(block)
            await asyncio.sleep(0.05)
            if not streamer.active:
                break

        await streamer.stop()
        total = sum(len(f) for f in sent)
        # Must receive well more than the 1s ring (32000 bytes).
        self.assertGreater(total, 32000 * 2)


if __name__ == "__main__":
    unittest.main()
