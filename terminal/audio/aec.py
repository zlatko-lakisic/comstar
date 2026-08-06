"""Acoustic echo cancellation for full-duplex barge-in (ADR 0007).

Uses SpeexDSP when available. Falls back to passthrough and reports unavailable
so the bridge can keep `audio.duplex: half`.

Reference PCM should be a monitor of the playback sink (PipeWire/Pulse).
Mic and reference must be the same sample rate (16 kHz mono s16le).
"""

from __future__ import annotations

import logging
import os
from typing import Any

log = logging.getLogger("comstar.aec")

SAMPLE_RATE = 16000


def aec_requested() -> bool:
    return os.environ.get("COMSTAR_AEC", "").strip().lower() in ("1", "true", "yes", "on")


def reference_device() -> str | None:
    """PipeWire/Pulse monitor source name, e.g. `alsa_output....monitor`."""
    raw = os.environ.get("COMSTAR_AEC_REF_SOURCE", "").strip()
    return raw or None


class AecProcessor:
    """Frame-based AEC. Input/output: int16 mono PCM (numpy arrays when used)."""

    def __init__(self, sample_rate: int = SAMPLE_RATE, frame_ms: int = 10) -> None:
        self.sample_rate = sample_rate
        self.frame_samples = max(1, int(sample_rate * frame_ms / 1000))
        self._impl: Any | None = None
        self.available = False
        self._init_backend()

    def _init_backend(self) -> None:
        try:
            import speexdsp  # type: ignore

            frame = self.frame_samples
            filt = frame * 10
            self._impl = speexdsp.EchoCanceller.create(frame, filt, self.sample_rate)
            self.available = True
            log.info("aec_ready backend=speexdsp frame=%s", frame)
        except Exception as exc:  # noqa: BLE001
            self._impl = None
            self.available = False
            log.warning("aec_unavailable detail=%s", exc)

    def process(self, mic: Any, reference: Any | None) -> Any:
        """Return echo-cancelled mic PCM (int16). Requires numpy at call time."""
        import numpy as np

        mic16 = np.asarray(mic, dtype=np.int16).reshape(-1)
        if not self.available or self._impl is None or reference is None:
            return mic16
        ref16 = np.asarray(reference, dtype=np.int16).reshape(-1)
        n = min(len(mic16), len(ref16))
        if n < self.frame_samples:
            return mic16
        usable = n - (n % self.frame_samples)
        out = np.empty(usable, dtype=np.int16)
        try:
            for i in range(0, usable, self.frame_samples):
                m = mic16[i : i + self.frame_samples].tobytes()
                r = ref16[i : i + self.frame_samples].tobytes()
                cleaned = self._impl.process(m, r)
                out[i : i + self.frame_samples] = np.frombuffer(cleaned, dtype=np.int16)
        except Exception as exc:  # noqa: BLE001
            log.warning("aec_process_failed detail=%s", exc)
            return mic16
        if usable < len(mic16):
            return np.concatenate([out, mic16[usable:]])
        return out


def build_aec() -> AecProcessor | None:
    """Construct AEC when COMSTAR_AEC is enabled; None otherwise."""
    if not aec_requested():
        return None
    proc = AecProcessor()
    if not proc.available:
        log.error("aec_unavailable forced_half_duplex=1")
    return proc
