#!/usr/bin/env python3
"""Generate minimal COMSTAR Plymouth PNGs (stdlib only)."""
from __future__ import annotations

import struct
import zlib
from pathlib import Path


def _chunk(tag: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + tag + data + struct.pack(
        ">I", zlib.crc32(tag + data) & 0xFFFFFFFF
    )


def write_png(path: Path, width: int, height: int, rgba_fn) -> None:
    rows = []
    for y in range(height):
        row = bytearray([0])  # filter none
        for x in range(width):
            row.extend(rgba_fn(x, y, width, height))
        rows.append(bytes(row))
    raw = b"".join(rows)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n"
    png += _chunk(b"IHDR", ihdr)
    png += _chunk(b"IDAT", zlib.compress(raw, 9))
    png += _chunk(b"IEND", b"")
    path.write_bytes(png)


def bg(x: int, y: int, w: int, h: int) -> bytes:
    # #06080B
    return bytes((0x06, 0x08, 0x0B, 0xFF))


def mark(x: int, y: int, w: int, h: int) -> bytes:
    cx, cy = w // 2, h // 2
    dx, dy = x - cx, y - cy
    # Soft cyan glow
    dist = (dx * dx + dy * dy) ** 0.5
    glow_r = min(w, h) * 0.22
    base = [0x06, 0x08, 0x0B]
    if dist < glow_r:
        t = 1.0 - (dist / glow_r)
        t = t * t
        base = [
            int(base[0] + (0x3D - base[0]) * t * 0.35),
            int(base[1] + (0xDC - base[1]) * t * 0.35),
            int(base[2] + (0xFF - base[2]) * t * 0.35),
        ]
    # Cross axes (cyan)
    thick = max(2, w // 180)
    if abs(dx) <= thick or abs(dy) <= thick:
        if dist < min(w, h) * 0.38:
            return bytes((0x3D, 0xDC, 0xFF, 0xFF))
    # Diagonals
    if abs(abs(dx) - abs(dy)) <= thick and dist < min(w, h) * 0.32:
        return bytes((0x3D, 0xDC, 0xFF, 0xE0))
    # Amber core
    if dist <= max(4, w // 48):
        return bytes((0xF0, 0xA2, 0x02, 0xFF))
    return bytes((base[0], base[1], base[2], 0xFF))


def spinner_ring(x: int, y: int, w: int, h: int) -> bytes:
    cx, cy = w // 2, h // 2
    dx, dy = x - cx, y - cy
    dist = (dx * dx + dy * dy) ** 0.5
    r = min(w, h) * 0.36
    if abs(dist - r) > 2.2:
        return bytes((0, 0, 0, 0))
    import math

    ang = (math.atan2(dy, dx) + math.pi) / (2 * math.pi)
    # Bright arc + dim trail so Rotate reads as a spinner.
    if ang < 0.3:
        a = int(255 * (1.0 - ang / 0.3))
        return bytes((0x3D, 0xDC, 0xFF, max(a, 60)))
    return bytes((0x3D, 0xDC, 0xFF, 36))


def main() -> None:
    out = Path(__file__).resolve().parent
    write_png(out / "background.png", 800, 480, bg)
    write_png(out / "mark.png", 400, 400, mark)
    write_png(out / "spinner-00.png", 96, 96, spinner_ring)
    print(f"wrote Plymouth assets under {out}")


if __name__ == "__main__":
    main()
