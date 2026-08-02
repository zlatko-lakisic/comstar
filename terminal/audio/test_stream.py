"""Unit tests for PCM streamer pre-roll and maxMs."""

from __future__ import annotations

import asyncio
import unittest

from stream import FRAME_BYTES, PRE_ROLL_BYTES, PcmStreamer


class FakeCapture:
    def __init__(self, data: bytes) -> None:
        self._data = data

    def snapshot(self) -> bytes:
        return self._data

    def clear_ring(self) -> None:
        self._data = b""


class StreamTests(unittest.IsolatedAsyncioTestCase):
    async def test_pre_roll_preserved(self) -> None:
        # Ring holds more than pre-roll; start must not clear it away.
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
        # max_ms in ms — one frame worth
        await streamer.start("t1", max_ms=320)
        await asyncio.sleep(0.05)
        await streamer.stop()
        self.assertTrue(any(t == "audio.begin" for t, _ in envelopes))
        self.assertTrue(any(t == "audio.end" for t, _ in envelopes))
        self.assertGreaterEqual(len(sent), 1)
        # First frame should include tail of pre-roll (non-zero from our pattern).
        self.assertNotEqual(sent[0], b"\x00" * FRAME_BYTES)

    async def test_max_ms_stops(self) -> None:
        # Growing capture: append silence each snapshot read via mutable buffer.
        buf = bytearray(b"\x00" * (FRAME_BYTES * 20))

        class Growing:
            def snapshot(self) -> bytes:
                return bytes(buf)

            def clear_ring(self) -> None:
                pass

        frames = 0

        async def send_binary(_data: bytes) -> None:
            nonlocal frames
            frames += 1

        async def send_envelope(_t: str, _d: dict, _tid: str | None = None) -> None:
            return None

        streamer = PcmStreamer(
            capture=Growing(),
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


if __name__ == "__main__":
    unittest.main()
