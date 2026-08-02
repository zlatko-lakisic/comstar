"""Wake word runtime — stub when model missing; train script deferred to M4.2."""

from __future__ import annotations

from pathlib import Path


class WakeWordEngine:
    """openWakeWord wrapper with never-fire stub fallback."""

    def __init__(self, model_path: str, threshold: float = 0.55) -> None:
        self.model_path = model_path
        self.threshold = threshold
        self._enabled = True
        self._model = None
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

    def process(self, pcm: bytes) -> float | None:
        """Return wake score if above threshold, else None."""
        if not self._enabled or self._model is None:
            return None
        try:
            import numpy as np

            audio = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
            scores = self._model.predict(audio)
            if not scores:
                return None
            best = max(float(v) for v in scores.values())
            if best >= self.threshold:
                return best
        except Exception:  # noqa: BLE001
            return None
        return None
