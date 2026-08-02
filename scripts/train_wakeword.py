#!/usr/bin/env python3
"""M4.2 wake-word training driver.

openWakeWord AutoTrainer needs Piper voices + negative corpus + room IR data.
Until that training environment is assembled, this script:

1. Documents the expected output path (`models/hey_comstar.onnx`)
2. Exits non-zero so CI/operators know the model is missing
3. Points at the runtime bypasses (dev inject `:8779`, `COMSTAR_FORCE_WAKE_SCORE`)

When training assets are available, replace the body with openWakeWord's
synthetic pipeline and write the ONNX + hyperparameters into docs/BASELINES.md.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUT = ROOT / "models" / "hey_comstar.onnx"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()

    print("wakeword training: not configured in this environment")
    print(f"expected model path: {args.out}")
    print("runtime bypasses while model is missing:")
    print("  - bridge dev inject: POST /inject WakeWord {\"score\":0.99}")
    print("  - audio env: COMSTAR_FORCE_WAKE_SCORE=0.99 (energy-gated)")
    print("  - audio message: wake.force from bridge")
    if args.out.exists():
        print(f"model already present ({args.out.stat().st_size} bytes)")
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
