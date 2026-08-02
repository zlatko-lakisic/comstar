"""Stream captured PCM to the bridge as 320 ms binary frames."""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable

SAMPLE_RATE = 16000
FRAME_MS = 320
FRAME_SAMPLES = int(SAMPLE_RATE * FRAME_MS / 1000)
FRAME_BYTES = FRAME_SAMPLES * 2


SendBinary = Callable[[bytes], Awaitable[None] | None]
SendEnvelope = Callable[[str, dict, str | None], Awaitable[None] | None]


class PcmStreamer:
    def __init__(
        self,
        *,
        capture,
        send_binary: SendBinary,
        send_envelope: SendEnvelope,
        vad=None,
    ) -> None:
        self.capture = capture
        self.send_binary = send_binary
        self.send_envelope = send_envelope
        self.vad = vad
        self._task: asyncio.Task[None] | None = None
        self._active = False
        self._turn_id: str | None = None
        self._read_offset = 0

    @property
    def active(self) -> bool:
        return self._active

    async def start(self, turn_id: str) -> None:
        await self.stop()
        self._turn_id = turn_id
        self._active = True
        self._read_offset = 0
        self.capture.clear_ring()
        if self.vad is not None:
            self.vad.reset()
        await _maybe_await(
            self.send_envelope(
                "audio.begin",
                {
                    "turn_id": turn_id,
                    "sampleRate": SAMPLE_RATE,
                    "encoding": "s16le",
                },
                turn_id,
            ),
        )
        self._task = asyncio.create_task(self._loop())

    async def stop(self) -> None:
        if not self._active and self._task is None:
            return
        self._active = False
        if self._task is not None:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
            self._task = None
        self._turn_id = None
        self._read_offset = 0

    async def _loop(self) -> None:
        frames = 0
        turn_id = self._turn_id
        try:
            while self._active:
                snapshot = self.capture.snapshot()
                while self._active and len(snapshot) - self._read_offset >= FRAME_BYTES:
                    start = self._read_offset
                    end = start + FRAME_BYTES
                    frame = snapshot[start:end]
                    self._read_offset = end
                    frames += 1

                    if self.vad is not None:
                        speech_start, speech_end = self.vad.process(frame)
                        if speech_start:
                            await _maybe_await(
                                self.send_envelope("vad.speech_start", {}, turn_id),
                            )
                        if speech_end:
                            await _maybe_await(
                                self.send_envelope(
                                    "vad.speech_end",
                                    {"durationMs": frames * FRAME_MS},
                                    turn_id,
                                ),
                            )

                    await _maybe_await(self.send_binary(frame))

                await asyncio.sleep(FRAME_MS / 1000 / 2)
        finally:
            if turn_id is not None:
                await _maybe_await(
                    self.send_envelope(
                        "audio.end",
                        {"frames": frames, "totalMs": frames * FRAME_MS},
                        turn_id,
                    ),
                )


async def _maybe_await(result: Awaitable[None] | None) -> None:
    if result is not None:
        await result
