"""Resolve COMSTAR mic/speaker device env vars for sounddevice / PulseAudio."""

from __future__ import annotations

import os
from typing import Any


def env_first(*names: str) -> str | None:
    for name in names:
        raw = os.environ.get(name)
        if raw is not None and raw.strip():
            return raw.strip()
    return None


def mic_source_spec() -> str | None:
    """COMSTAR_MIC_SOURCE (preferred) or COMSTAR_MIC_DEVICE."""
    return env_first("COMSTAR_MIC_SOURCE", "COMSTAR_MIC_DEVICE")


def speaker_source_spec() -> str | None:
    """COMSTAR_SPEAKER_SOURCE (preferred) or COMSTAR_SPEAKER_SINK / COMSTAR_AUDIO_SINK."""
    return env_first(
        "COMSTAR_SPEAKER_SOURCE",
        "COMSTAR_SPEAKER_SINK",
        "COMSTAR_AUDIO_SINK",
    )


def resolve_sounddevice_input(spec: str | None) -> int | str | None:
    """Map an env spec to a sounddevice ``device=`` value.

    Accepts:
      * empty / None → system default (``None``)
      * integer string → device index
      * name substring → first input device whose name contains it (case-insensitive)
    """
    if spec is None or not spec.strip():
        return None
    text = spec.strip()
    if text.isdigit() or (text.startswith("-") and text[1:].isdigit()):
        return int(text)

    try:
        import sounddevice as sd
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError("sounddevice is not installed") from exc

    devices: list[dict[str, Any]] = list(sd.query_devices())
    needle = text.lower()
    for idx, dev in enumerate(devices):
        if int(dev.get("max_input_channels") or 0) <= 0:
            continue
        name = str(dev.get("name") or "")
        if needle in name.lower():
            return idx
    raise ValueError(
        f"No sounddevice input matching {text!r}. "
        f"Set COMSTAR_MIC_SOURCE to an index or name substring."
    )


def describe_input_device(device: int | str | None) -> dict[str, Any]:
    """Best-effort device info for logs (never raises)."""
    try:
        import sounddevice as sd

        # ``query_devices(None)`` returns the full DeviceList (no ``.get``).
        info = (
            sd.query_devices(kind="input")
            if device is None
            else sd.query_devices(device)
        )
        if not isinstance(info, dict):
            return {"device": device if device is not None else "default"}
        return {
            "device": device if device is not None else "default",
            "name": info.get("name"),
            "max_input_channels": info.get("max_input_channels"),
            "default_samplerate": info.get("default_samplerate"),
        }
    except Exception as exc:  # noqa: BLE001
        return {"device": device if device is not None else "default", "error": str(exc)}
