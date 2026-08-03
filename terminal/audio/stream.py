"""Stream captured PCM to the bridge as 320 ms binary frames."""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable

SAMPLE_RATE = 16000
FRAME_MS = 320
FRAME_SAMPLES = int(SAMPLE_RATE * FRAME_MS / 1000)
FRAME_BYTES = FRAME_SAMPLES * 2
# Include ring audio before listen.start so speech overlapping the wake word is kept.
# Follow-up turns pass preRollMs=0 — ambient pre-roll was ending as a 1.9s junk utterance.
DEFAULT_PRE_ROLL_MS = 2000
PRE_ROLL_BYTES = int(SAMPLE_RATE * DEFAULT_PRE_ROLL_MS / 1000) * 2
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
        self._sample_offset = 0
        self._pending: bytes = b""
        self._started_ms = 0
        self._vad_live = False
        self._vad_settle_ms = VAD_SETTLE_MS

    @property
    def active(self) -> bool:
        return self._active

    def _cursor_now(self) -> int:
        if hasattr(self.capture, "written_samples"):
            return int(self.capture.written_samples)
        # Test doubles that only expose snapshot(): treat length as cursor.
        snap = self.capture.snapshot()
        return len(snap) // 2

    def _read_new(self) -> bytes:
        """Pull samples written since ``_sample_offset`` (ring-wrap safe)."""
        if hasattr(self.capture, "read_since"):
            data, self._sample_offset = self.capture.read_since(self._sample_offset)
            return data
        # Legacy / test capture: append-only snapshot.
        snap = self.capture.snapshot()
        byte_off = self._sample_offset * 2
        if byte_off > len(snap):
            byte_off = max(0, len(snap) - FRAME_BYTES)
            self._sample_offset = byte_off // 2
        data = snap[byte_off:]
        self._sample_offset = len(snap) // 2
        return data

    async def start(
        self,
        turn_id: str,
        *,
        max_ms: int | None = None,
        pre_roll_ms: int | None = None,
        vad_settle_ms: int | None = None,
        clear_ring: bool | None = None,
    ) -> None:
        await self.stop()
        self._turn_id = turn_id
        self._active = True
        if max_ms is not None:
            self.max_ms = max_ms
        self._vad_settle_ms = (
            VAD_SETTLE_MS if vad_settle_ms is None else max(0, int(vad_settle_ms))
        )

        roll_ms = DEFAULT_PRE_ROLL_MS if pre_roll_ms is None else max(0, int(pre_roll_ms))
        roll_samples = int(SAMPLE_RATE * roll_ms / 1000)

        should_clear = True if clear_ring is None else bool(clear_ring)
        if roll_samples <= 0:
            if (
                should_clear
                and hasattr(self.capture, "ring")
                and hasattr(self.capture.ring, "clear")
            ):
                self.capture.ring.clear()
            elif should_clear and hasattr(self.capture, "clear_ring"):
                self.capture.clear_ring()
            # Start cursor at "now" so we only stream live audio.
            self._sample_offset = self._cursor_now()
            self._pending = b""
        else:
            # Seed with the last roll_ms already in the ring, then stream live.
            now = self._cursor_now()
            start = max(0, now - roll_samples)
            if hasattr(self.capture, "read_since"):
                self._pending, self._sample_offset = self.capture.read_since(start)
            else:
                snap = self.capture.snapshot()
                roll_bytes = roll_samples * 2
                self._pending = snap[-roll_bytes:] if len(snap) >= roll_bytes else snap
                self._sample_offset = len(snap) // 2

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
                    "preRollMs": roll_ms,
                    "vadSettleMs": self._vad_settle_ms,
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
        self._sample_offset = 0
        self._pending = b""

    async def _loop(self) -> None:
        frames = 0
        turn_id = self._turn_id
        speech_ended = False
        try:
            while self._active:
                chunk = self._pending + self._read_new()
                self._pending = b""

                while self._active and len(chunk) >= FRAME_BYTES:
                    frame = chunk[:FRAME_BYTES]
                    chunk = chunk[FRAME_BYTES:]
                    frames += 1
                    self._started_ms = frames * FRAME_MS

                    if self.vad is not None and not speech_ended:
                        if self._started_ms < self._vad_settle_ms:
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
