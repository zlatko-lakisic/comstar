"""Microphone capture with a 3 s in-memory ring buffer (never written to disk)."""

from __future__ import annotations

import threading
from collections import deque
from typing import Callable

import numpy as np

try:
    import sounddevice as sd
except ImportError:  # pragma: no cover - optional at import time
    sd = None  # type: ignore[assignment]

SAMPLE_RATE = 16000
CHANNELS = 1
DTYPE = "int16"
RING_SECONDS = 3.0


class RingBuffer:
    """Fixed-duration PCM s16le ring buffer."""

    def __init__(self, sample_rate: int = SAMPLE_RATE, seconds: float = RING_SECONDS) -> None:
        self.sample_rate = sample_rate
        self.max_samples = int(sample_rate * seconds)
        self._chunks: deque[np.ndarray] = deque()
        self._total = 0

    def write(self, pcm: np.ndarray) -> None:
        flat = np.asarray(pcm, dtype=np.int16).reshape(-1)
        if flat.size == 0:
            return
        self._chunks.append(flat)
        self._total += flat.size
        while self._total > self.max_samples and self._chunks:
            dropped = self._chunks.popleft()
            self._total -= dropped.size

    def read_all(self) -> bytes:
        if not self._chunks:
            return b""
        merged = np.concatenate(list(self._chunks))
        return merged.astype(np.int16).tobytes()

    def clear(self) -> None:
        self._chunks.clear()
        self._total = 0

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
        on_level: Callable[[float], None] | None = None,
    ) -> None:
        self.sample_rate = sample_rate
        self.block_ms = block_ms
        self.on_level = on_level
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
        with self._lock:
            self.ring.write(pcm)
        if self.on_level is not None:
            rms = float(np.sqrt(np.mean(np.square(pcm.astype(np.float32) / 32768.0))))
            self.on_level(min(1.0, rms * 4.0))

    def snapshot(self) -> bytes:
        with self._lock:
            return self.ring.read_all()

    def clear_ring(self) -> None:
        with self._lock:
            self.ring.clear()
