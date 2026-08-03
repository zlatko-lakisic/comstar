"""Simple soft AGC for int16 mono PCM (no hardware AGC on C525)."""

from __future__ import annotations

import os

import numpy as np


class SoftAgc:
    """Slow gain toward a speech RMS target; does not boost near-silence."""

    def __init__(
        self,
        *,
        target_rms: float = 0.07,
        max_gain: float = 2.5,
        min_gain: float = 0.4,
        noise_floor: float = 0.008,
        attack: float = 0.2,
        release: float = 0.06,
    ) -> None:
        self.target_rms = target_rms
        self.max_gain = max_gain
        self.min_gain = min_gain
        self.noise_floor = noise_floor
        self.attack = attack
        self.release = release
        self.gain = 1.0

    def process(self, pcm: np.ndarray) -> np.ndarray:
        flat = np.asarray(pcm, dtype=np.int16).reshape(-1)
        if flat.size == 0:
            return flat
        samples = flat.astype(np.float32) / 32768.0
        rms = float(np.sqrt(np.mean(np.square(samples))))
        if rms >= self.noise_floor:
            desired = self.target_rms / max(rms, 1e-6)
            desired = float(np.clip(desired, self.min_gain, self.max_gain))
            alpha = self.attack if desired < self.gain else self.release
            self.gain = (1.0 - alpha) * self.gain + alpha * desired
        # Near silence: gently release toward 1.0 so idle hiss is not amplified.
        elif self.gain > 1.0:
            self.gain = (1.0 - self.release) * self.gain + self.release * 1.0

        out = np.clip(samples * self.gain, -1.0, 1.0)
        return (out * 32767.0).astype(np.int16)


def agc_from_env() -> SoftAgc | None:
    """Enable with COMSTAR_MIC_AGC=1 (default on). Set 0 to disable."""
    raw = os.environ.get("COMSTAR_MIC_AGC", "1").strip().lower()
    if raw in {"0", "false", "off", "no"}:
        return None
    target = float(os.environ.get("COMSTAR_MIC_AGC_TARGET", "0.07"))
    max_gain = float(os.environ.get("COMSTAR_MIC_AGC_MAX_GAIN", "2.5"))
    return SoftAgc(target_rms=target, max_gain=max_gain)
