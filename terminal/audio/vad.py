"""Voice activity detection — Silero via torch hub or energy fallback."""

from __future__ import annotations

import numpy as np


class VadEngine:
    def __init__(
        self,
        silence_ms: int = 700,
        sample_rate: int = 16000,
        *,
        energy_threshold: float = 0.04,
        # Once speech has started, allow softer frames so fast speech /
        # unvoiced consonants do not trip end-of-utterance early.
        continue_threshold: float | None = None,
        min_speech_ms: int = 500,
        start_hold_ms: int = 200,
    ) -> None:
        self.silence_ms = silence_ms
        self.sample_rate = sample_rate
        self.energy_threshold = energy_threshold
        self.continue_threshold = (
            energy_threshold * 0.55 if continue_threshold is None else continue_threshold
        )
        self.min_speech_ms = min_speech_ms
        self.start_hold_ms = start_hold_ms
        self._silero = None
        self._speech = False
        self._silence_samples = 0
        self._speech_samples = 0
        self._pending_start_samples = 0
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
        self._pending_start_samples = 0

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
        start_hold = int(self.sample_rate * self.start_hold_ms / 1000)
        min_speech = int(self.sample_rate * self.min_speech_ms / 1000)
        silence_needed = int(self.sample_rate * self.silence_ms / 1000)

        if is_speech:
            self._silence_samples = 0
            if not self._speech:
                self._pending_start_samples += samples.size
                # Require sustained energy before promoting — single-frame
                # room spikes were arming Listening on ambient hiss.
                if self._pending_start_samples >= start_hold:
                    speech_start = True
                    self._speech = True
                    self._speech_samples = self._pending_start_samples
                    self._pending_start_samples = 0
            else:
                self._speech_samples += samples.size
        else:
            self._pending_start_samples = 0
            if self._speech:
                self._silence_samples += samples.size
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
        # Idle C525 @100% ~0.01–0.02. Soft speech across the room ~0.05–0.12.
        # Hysteresis: harder to start than to stay in speech — fast talkers
        # dip below the start gate between words without being done.
        gate = self.continue_threshold if self._speech else self.energy_threshold
        return rms > gate
