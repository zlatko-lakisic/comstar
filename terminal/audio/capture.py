"""Microphone capture with a 3 s in-memory ring buffer (never written to disk)."""

from __future__ import annotations

import threading
from collections import deque
from typing import Callable

import numpy as np

try:
    from agc import SoftAgc
except ImportError:  # pragma: no cover
    SoftAgc = None  # type: ignore[misc, assignment]

try:
    import sounddevice as sd
except ImportError:  # pragma: no cover - optional at import time
    sd = None  # type: ignore[assignment]

SAMPLE_RATE = 16000
CHANNELS = 1
DTYPE = "int16"
RING_SECONDS = 3.0


class RingBuffer:
    """Fixed-duration PCM s16le ring with a monotonic write cursor.

    Consumers must use ``read_since(sample_offset)`` — indexing into
    ``read_all()`` breaks once the ring wraps, because new samples reuse
    the same absolute indices in the returned buffer.
    """

    def __init__(self, sample_rate: int = SAMPLE_RATE, seconds: float = RING_SECONDS) -> None:
        self.sample_rate = sample_rate
        self.max_samples = int(sample_rate * seconds)
        self._chunks: deque[np.ndarray] = deque()
        self._total = 0
        # Total samples ever written (never decreases on drop/clear of unread).
        self._written = 0

    def write(self, pcm: np.ndarray) -> None:
        flat = np.asarray(pcm, dtype=np.int16).reshape(-1)
        if flat.size == 0:
            return
        self._chunks.append(flat)
        self._total += flat.size
        self._written += flat.size
        while self._total > self.max_samples and self._chunks:
            dropped = self._chunks.popleft()
            self._total -= dropped.size

    def read_all(self) -> bytes:
        if not self._chunks:
            return b""
        merged = np.concatenate(list(self._chunks))
        return merged.astype(np.int16).tobytes()

    def read_since(self, sample_offset: int) -> tuple[bytes, int]:
        """Return PCM written after ``sample_offset`` and the new cursor.

        If ``sample_offset`` lags behind the ring (data was dropped before it
        was read), start from the oldest sample still available.
        """
        if sample_offset < 0:
            sample_offset = 0
        if not self._chunks:
            return b"", max(sample_offset, self._written)

        oldest = self._written - self._total
        if sample_offset < oldest:
            sample_offset = oldest
        if sample_offset >= self._written:
            return b"", self._written

        merged = np.concatenate(list(self._chunks))
        start = int(sample_offset - oldest)
        data = merged[start:].astype(np.int16).tobytes()
        return data, self._written

    @property
    def written_samples(self) -> int:
        return self._written

    def clear(self) -> None:
        self._chunks.clear()
        self._total = 0
        # Keep _written so consumers can resync without replaying ghost audio.

    @property
    def duration_ms(self) -> int:
        return int(self._total / self.sample_rate * 1000)


class AudioCapture:
    """sounddevice input with level callbacks and ring buffer."""

    def __init__(
        self,
        *,
        sample_rate: int = SAMPLE_RATE,
        block_ms: int = 100,
        device: int | str | None = None,
        on_level: Callable[[float], None] | None = None,
        agc: SoftAgc | None = None,
    ) -> None:
        self.sample_rate = sample_rate
        self.block_ms = block_ms
        self.device = device
        self.on_level = on_level
        self.agc = agc
        self.ring = RingBuffer(sample_rate=sample_rate, seconds=RING_SECONDS)
        self._stream: sd.InputStream | None = None
        self._lock = threading.Lock()
        self._running = False

    def start(self) -> None:
        if sd is None:
            raise RuntimeError("sounddevice is not installed")
        if self._running:
            return
        blocksize = max(1, int(self.sample_rate * self.block_ms / 1000))
        self._stream = sd.InputStream(
            samplerate=self.sample_rate,
            channels=CHANNELS,
            dtype=DTYPE,
            blocksize=blocksize,
            device=self.device,
            callback=self._callback,
        )
        self._stream.start()
        self._running = True

    def stop(self) -> None:
        self._running = False
        if self._stream is not None:
            self._stream.stop()
            self._stream.close()
            self._stream = None

    def _callback(
        self,
        indata: np.ndarray,
        frames: int,
        time_info: object,
        status: sd.CallbackFlags,
    ) -> None:
        if status:
            return
        pcm = np.asarray(indata[:, 0], dtype=np.int16)
        if self.agc is not None:
            pcm = self.agc.process(pcm)
        with self._lock:
            self.ring.write(pcm)
        if self.on_level is not None:
            rms = float(np.sqrt(np.mean(np.square(pcm.astype(np.float32) / 32768.0))))
            self.on_level(min(1.0, rms * 4.0))

    def snapshot(self) -> bytes:
        with self._lock:
            return self.ring.read_all()

    def read_since(self, sample_offset: int) -> tuple[bytes, int]:
        with self._lock:
            return self.ring.read_since(sample_offset)

    @property
    def written_samples(self) -> int:
        with self._lock:
            return self.ring.written_samples

    def clear_ring(self) -> None:
        with self._lock:
            self.ring.clear()
