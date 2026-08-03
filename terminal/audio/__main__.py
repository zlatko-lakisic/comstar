"""COMSTAR audio process — capture, wake word, VAD, PCM streaming."""

from __future__ import annotations

import asyncio
import os
import signal
from typing import Any

from agc import agc_from_env
from bridge_client import BridgeClient
from capture import AudioCapture
from devices import describe_input_device, mic_source_spec, resolve_sounddevice_input
from log import log_info, log_warn
from stream import PcmStreamer
from vad import VadEngine
from wakeword import WakeWordEngine


async def _main() -> None:
    wakeword_model = os.environ.get(
        "COMSTAR_WAKEWORD_MODEL",
        "./models/hey_comstar.onnx",
    )
    wakeword_threshold = float(os.environ.get("COMSTAR_WAKEWORD_THRESHOLD", "0.55"))
    vad_silence_ms = int(os.environ.get("COMSTAR_VAD_SILENCE_MS", "1000"))
    # Dev bypass when ONNX is missing — score must exceed threshold (default 0.55).
    force_wake_score = os.environ.get("COMSTAR_FORCE_WAKE_SCORE") or None
    if force_wake_score is not None and not force_wake_score.strip():
        force_wake_score = None

    mic_spec = mic_source_spec()
    try:
        mic_device = resolve_sounddevice_input(mic_spec)
    except Exception as exc:  # noqa: BLE001
        log_warn("mic_source_invalid", str(exc), data={"spec": mic_spec})
        raise

    client = BridgeClient()
    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()
    level_task: asyncio.Task[None] | None = None
    wake_enabled = True
    capture: AudioCapture | None = None
    streamer: PcmStreamer | None = None
    wake: WakeWordEngine | None = None
    vad: VadEngine | None = None

    async def send_envelope(
        msg_type: str,
        data: dict[str, Any],
        turn_id: str | None = None,
    ) -> None:
        await client.send(msg_type, data, turn_id=turn_id)

    async def send_binary(data: bytes) -> None:
        await client.send_binary(data)

    try:
        agc = agc_from_env()
        capture = AudioCapture(device=mic_device, on_level=lambda _rms: None, agc=agc)
        capture.start()
        vad = VadEngine(silence_ms=vad_silence_ms)
        wake = WakeWordEngine(wakeword_model, threshold=wakeword_threshold)
        streamer = PcmStreamer(
            capture=capture,
            send_binary=send_binary,
            send_envelope=send_envelope,
            vad=vad,
        )
        log_info(
            "audio_started",
            "Audio capture running",
            data={
                "wakeword_available": wake.available,
                "force_wake": force_wake_score is not None,
                "vad": "silero" if vad.using_silero else "energy",
                "mic_source": mic_spec or "default",
                "mic_device": describe_input_device(mic_device),
                "mic_agc": agc is not None,
            },
        )
    except Exception as exc:  # noqa: BLE001
        log_warn("audio_capture_unavailable", str(exc))

    async def on_message(envelope: dict[str, Any]) -> None:
        nonlocal wake_enabled, level_task
        msg_type = envelope.get("type")
        data = envelope.get("data") or {}
        turn_id = envelope.get("turn_id")

        if msg_type == "listen.start":
            if streamer is not None:
                tid = data.get("turn_id") or turn_id or "unknown"
                max_ms = data.get("maxMs")
                pre_roll = data.get("preRollMs")
                vad_settle = data.get("vadSettleMs")
                clear_ring = data.get("clearRing")
                await streamer.start(
                    str(tid),
                    max_ms=int(max_ms) if max_ms is not None else None,
                    pre_roll_ms=int(pre_roll) if pre_roll is not None else None,
                    vad_settle_ms=int(vad_settle) if vad_settle is not None else None,
                    clear_ring=bool(clear_ring) if clear_ring is not None else None,
                )
        elif msg_type == "listen.stop":
            if streamer is not None:
                await streamer.stop()
        elif msg_type == "wake.enable":
            wake_enabled = bool(data.get("enabled", True))
            if wake is not None:
                wake.set_enabled(wake_enabled)
        elif msg_type == "wake.force":
            # Dev/test inject from bridge — still respects wake.enable.
            if wake_enabled:
                score = float(data.get("score", 0.99))
                await client.send(
                    "wake",
                    {"score": score, "model": data.get("model", "force")},
                )

    client.on_message = on_message

    if capture is not None:
        last_holder = {"rms": 0.0}

        def _on_level(rms: float) -> None:
            last_holder["rms"] = rms

        capture.on_level = _on_level

        async def emit_levels() -> None:
            while not stop_event.is_set():
                await client.send("level", {"rms": last_holder["rms"]})
                if wake_enabled and wake is not None and capture is not None:
                    pcm = capture.snapshot()
                    if len(pcm) >= 3200:
                        score = wake.process(pcm[-3200:])
                        if score is None and force_wake_score is not None:
                            # Energy gate so silence does not spam forced wakes.
                            import numpy as np

                            audio = np.frombuffer(pcm[-3200:], dtype=np.int16).astype(
                                np.float32,
                            )
                            rms = float(np.sqrt(np.mean(np.square(audio / 32768.0))))
                            # Idle C525 @100% ~0.01–0.02; soft speech often ~0.06–0.12.
                            if rms > 0.10:
                                score = float(force_wake_score)
                                wake.mark_fired()
                        if score is not None:
                            await client.send(
                                "wake",
                                {
                                    "score": score,
                                    "model": "hey_comstar" if wake.available else "force",
                                },
                            )
                await asyncio.sleep(0.1)

        level_task = asyncio.create_task(emit_levels())

    def _shutdown() -> None:
        log_info("shutdown", "SIGTERM received, stopping")
        stop_event.set()

    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, _shutdown)

    runner = asyncio.create_task(client.run())
    await stop_event.wait()
    if level_task is not None:
        level_task.cancel()
        try:
            await level_task
        except asyncio.CancelledError:
            pass
    if streamer is not None:
        await streamer.stop()
    if capture is not None:
        capture.stop()
    await client.stop()
    runner.cancel()
    try:
        await runner
    except asyncio.CancelledError:
        pass


def main() -> None:
    asyncio.run(_main())


if __name__ == "__main__":
    main()
