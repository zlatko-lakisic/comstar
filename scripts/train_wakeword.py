#!/usr/bin/env python3
"""Train an openWakeWord model for 'hey comstar' (M4.2).

This is a thin driver around the openWakeWord synthetic training pipeline.
Full training requires: piper TTS (or similar), openwakeword training extras,
room impulse responses, and a negative corpus — see docs/IMPLEMENTATION_PLAN.md M4.2.

Usage:
  python scripts/train_wakeword.py --phrase "hey comstar" --out terminal/audio/models/hey_comstar.onnx
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--phrase", default="hey comstar")
    p.add_argument("--out", type=Path, default=Path("terminal/audio/models/hey_comstar.onnx"))
    p.add_argument("--n-samples", type=int, default=20000)
    p.add_argument("--tts", default="piper")
    args = p.parse_args()

    try:
        import openwakeword  # noqa: F401
    except ImportError:
        print(
            "openwakeword is not installed. Create a training venv and install\n"
            "openwakeword[train] (and Piper) before running this script.\n"
            "Until then the audio process uses a wake-word stub that never fires.",
            file=sys.stderr,
        )
        return 2

    args.out.parent.mkdir(parents=True, exist_ok=True)
    print(
        f"Training stub: phrase={args.phrase!r} n={args.n_samples} out={args.out}\n"
        "Wire the openWakeWord AutoTrainer / custom trainer here once the training\n"
        "environment is provisioned (see IMPLEMENTATION_PLAN M4.2).",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
