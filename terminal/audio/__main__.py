"""COMSTAR audio process — M1 skeleton (connect + hello + reconnect)."""

from __future__ import annotations

import asyncio
import signal

from bridge_client import BridgeClient
from log import log_info


async def _main() -> None:
    client = BridgeClient()
    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()

    def _shutdown() -> None:
        log_info("shutdown", "SIGTERM received, stopping")
        stop_event.set()

    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, _shutdown)

    runner = asyncio.create_task(client.run())
    await stop_event.wait()
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
