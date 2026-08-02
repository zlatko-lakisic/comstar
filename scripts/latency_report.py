#!/usr/bin/env python3
"""Summarize COMSTAR JSONL span logs (M6.5).

Reads bridge stdout JSON lines with evt=span or data.ms / name fields.
Usage: python3 scripts/latency_report.py bridge.jsonl
"""

from __future__ import annotations

import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path


def load_spans(path: Path) -> dict[str, list[float]]:
    buckets: dict[str, list[float]] = defaultdict(list)
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        name = None
        ms = None
        if obj.get("evt") == "span":
            data = obj.get("data") or {}
            name = data.get("name") or obj.get("msg")
            ms = data.get("ms")
        elif "span" in obj:
            name = obj["span"].get("name")
            ms = obj["span"].get("ms")
        if name is not None and ms is not None:
            buckets[str(name)].append(float(ms))
    return buckets


def pct(values: list[float], p: float) -> float:
    if not values:
        return float("nan")
    ordered = sorted(values)
    idx = min(len(ordered) - 1, max(0, int(round((p / 100.0) * (len(ordered) - 1)))))
    return ordered[idx]


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: latency_report.py <jsonl>", file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    buckets = load_spans(path)
    if not buckets:
        print("No spans found.")
        return 1
    print(f"{'span':20} {'n':>5} {'p50':>8} {'p95':>8} {'mean':>8}")
    for name in sorted(buckets):
        vals = buckets[name]
        print(
            f"{name:20} {len(vals):5d} {pct(vals,50):8.1f} {pct(vals,95):8.1f} "
            f"{statistics.fmean(vals):8.1f}",
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
