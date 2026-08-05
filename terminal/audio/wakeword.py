"""Wake word runtime — openWakeWord when model present; never-fire stub otherwise."""

from __future__ import annotations

import time
from pathlib import Path

REFRACTORY_S = 2.0


class WakeWordEngine:
    """openWakeWord wrapper with never-fire stub fallback and 2 s refractory."""

    def __init__(
        self,
        model_path: str,
        threshold: float = 0.55,
        refractory_s: float = REFRACTORY_S,
    ) -> None:
        self.model_path = model_path
        self.threshold = threshold
        self.refractory_s = refractory_s
        self._enabled = True
        self._model = None
        self._last_fire_monotonic = 0.0
        self._load()

    def _load(self) -> None:
        path = Path(self.model_path)
        if not path.exists():
            self._model = None
            return
        try:
            from openwakeword.model import Model  # type: ignore[import-untyped]

            self._model = Model(wakeword_models=[str(path)])
        except Exception:  # noqa: BLE001 — bring-up stub
            self._model = None

    @property
    def available(self) -> bool:
        return self._model is not None

    def set_enabled(self, enabled: bool) -> None:
        self._enabled = enabled

    def mark_fired(self) -> None:
        """Start refractory (used by force-wake / inject paths)."""
        self._last_fire_monotonic = time.monotonic()

    def can_fire(self) -> bool:
        """True when wake is enabled and past refractory (ONNX or force-wake)."""
        if not self._enabled:
            return False
        return (time.monotonic() - self._last_fire_monotonic) >= self.refractory_s

    def process(self, pcm: bytes) -> float | None:
        """Return wake score if above threshold and past refractory, else None."""
        if not self.can_fire() or self._model is None:
            return None
        try:
            import numpy as np

            audio = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
            scores = self._model.predict(audio)
            if not scores:
                return None
            best = max(float(v) for v in scores.values())
            if best >= self.threshold:
                self.mark_fired()
                return best
        except Exception:  # noqa: BLE001
            return None
        return None
