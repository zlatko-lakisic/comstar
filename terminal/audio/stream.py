"""Stream captured PCM to the bridge as 320 ms binary frames."""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable

SAMPLE_RATE = 16000
FRAME_MS = 320
FRAME_SAMPLES = int(SAMPLE_RATE * FRAME_MS / 1000)
FRAME_BYTES = FRAME_SAMPLES * 2
# Include ring audio before listen.start so speech overlapping the wake word is kept.
PRE_ROLL_MS = 2000
PRE_ROLL_BYTES = int(SAMPLE_RATE * PRE_ROLL_MS / 1000) * 2
# Ignore VAD right after listen.start so HDMI TTS echo does not end the turn.
VAD_SETTLE_MS = 1500


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
        max_ms: int | None = None,
    ) -> None:
        self.capture = capture
        self.send_binary = send_binary
        self.send_envelope = send_envelope
        self.vad = vad
        self.max_ms = max_ms
        self._task: asyncio.Task[None] | None = None
        self._active = False
        self._turn_id: str | None = None
        self._read_offset = 0
        self._pending: bytes = b""
        self._started_ms = 0
        self._vad_live = False

    @property
    def active(self) -> bool:
        return self._active

    async def start(self, turn_id: str, *, max_ms: int | None = None) -> None:
        await self.stop()
        self._turn_id = turn_id
        self._active = True
        if max_ms is not None:
            self.max_ms = max_ms

        # Preserve pre-roll from the ring; do NOT clear before reading.
        snapshot = self.capture.snapshot()
        if len(snapshot) >= PRE_ROLL_BYTES:
            self._pending = snapshot[-PRE_ROLL_BYTES:]
        else:
            self._pending = snapshot
        self._read_offset = len(snapshot)
        self._started_ms = 0
        self._vad_live = False

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
        self._pending = b""

    async def _loop(self) -> None:
        frames = 0
        turn_id = self._turn_id
        speech_ended = False
        try:
            while self._active:
                snapshot = self.capture.snapshot()
                if self._read_offset > len(snapshot):
                    # Ring wrapped / cleared — resync without dropping new audio.
                    self._read_offset = max(0, len(snapshot) - FRAME_BYTES)

                chunk = self._pending + snapshot[self._read_offset :]
                self._pending = b""
                self._read_offset = len(snapshot)

                while self._active and len(chunk) >= FRAME_BYTES:
                    frame = chunk[:FRAME_BYTES]
                    chunk = chunk[FRAME_BYTES:]
                    frames += 1
                    self._started_ms = frames * FRAME_MS

                    if self.vad is not None and not speech_ended:
                        if self._started_ms < VAD_SETTLE_MS:
                            # Still settling after TTS — keep streaming PCM but
                            # do not emit speech_start/end from echo.
                            pass
                        else:
                            if not self._vad_live:
                                self.vad.reset()
                                self._vad_live = True
                            speech_start, speech_end = self.vad.process(frame)
                            if speech_start:
                                await _maybe_await(
                                    self.send_envelope("vad.speech_start", {}, turn_id),
                                )
                            if speech_end:
                                speech_ended = True
                                await _maybe_await(
                                    self.send_envelope(
                                        "vad.speech_end",
                                        {"durationMs": self._started_ms},
                                        turn_id,
                                    ),
                                )

                    await _maybe_await(self.send_binary(frame))

                    if self.max_ms is not None and self._started_ms >= self.max_ms:
                        self._active = False
                        break

                self._pending = chunk
                if speech_ended or not self._active:
                    break
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
