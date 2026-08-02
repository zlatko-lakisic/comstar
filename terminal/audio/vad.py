"""Voice activity detection — Silero via torch hub or energy fallback."""

from __future__ import annotations

import numpy as np


class VadEngine:
    def __init__(self, silence_ms: int = 700, sample_rate: int = 16000) -> None:
        self.silence_ms = silence_ms
        self.sample_rate = sample_rate
        self._silero = None
        self._speech = False
        self._silence_samples = 0
        self._speech_samples = 0
        self._load_silero()

    def _load_silero(self) -> None:
        try:
            import torch

            model, utils = torch.hub.load(  # type: ignore[no-untyped-call]
                repo_or_dir="snakers4/silero-vad",
                model="silero_vad",
                force_reload=False,
                onnx=False,
            )
            self._silero = (model, utils)
        except Exception:  # noqa: BLE001 — energy fallback for bring-up
            self._silero = None

    @property
    def using_silero(self) -> bool:
        return self._silero is not None

    def reset(self) -> None:
        self._speech = False
        self._silence_samples = 0
        self._speech_samples = 0

    def process(self, pcm: bytes) -> tuple[bool | None, bool | None]:
        """Returns (speech_start, speech_end) flags for this chunk."""
        if len(pcm) < 2:
            return None, None
        samples = np.frombuffer(pcm, dtype=np.int16)
        if self._silero is not None:
            is_speech = self._silero_detect(samples)
        else:
            is_speech = self._energy_detect(samples)

        speech_start: bool | None = None
        speech_end: bool | None = None

        if is_speech:
            if not self._speech:
                speech_start = True
            self._speech = True
            self._silence_samples = 0
            self._speech_samples += samples.size
        else:
            if self._speech:
                self._silence_samples += samples.size
                silence_needed = int(self.sample_rate * self.silence_ms / 1000)
                # Require a bit of real speech before allowing end (avoids
                # one-frame wake blips ending the utterance immediately).
                min_speech = int(self.sample_rate * 1.0)  # 1.0s
                if (
                    self._silence_samples >= silence_needed
                    and self._speech_samples >= min_speech
                ):
                    speech_end = True
                    self._speech = False
                    self._silence_samples = 0
                    self._speech_samples = 0

        return speech_start, speech_end

    def _silero_detect(self, samples: np.ndarray) -> bool:
        model, utils = self._silero  # type: ignore[misc]
        get_speech_timestamps = utils[0]
        import torch

        audio = torch.from_numpy(samples.astype(np.float32) / 32768.0)
        timestamps = get_speech_timestamps(audio, model, sampling_rate=self.sample_rate)
        return len(timestamps) > 0

    def _energy_detect(self, samples: np.ndarray) -> bool:
        rms = float(np.sqrt(np.mean(np.square(samples.astype(np.float32) / 32768.0))))
        # Idle webcam hiss sits ~0.05–0.06 RMS at 100–180% gain.
        # Real close speech peaks well above 0.2. Stay clear of idle.
        return rms > 0.10
