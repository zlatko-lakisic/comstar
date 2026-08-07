#!/usr/bin/env python3
"""Append/replace §12 Kokoro TTS.0 results in docs/BASELINES.md from a bench JSON."""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--json", type=Path, required=True)
    p.add_argument("--baselines", type=Path, required=True)
    p.add_argument("--stamp", required=True)
    p.add_argument("--host", required=True)
    args = p.parse_args()

    data = json.loads(args.json.read_text())
    summaries = data.get("summaries") or {}
    api = data.get("streaming_api") or {}
    host = args.host.split("@")[-1]
    methods = "`, `".join(api.get("offline_tts_methods") or [])
    sr = (summaries.get("idle") or summaries.get("contended") or {}).get(
        "sample_rate", "?"
    )

    lines = [
        "",
        f"## 12. Kokoro TTS on Ada (TTS.0) — {args.stamp}",
        "",
        f"Captured by `scripts/verify_tts.sh` → `docs/fixtures/kokoro_bench_{args.stamp}.json`.",
        "",
        "| Field | Value |",
        "|---|---|",
        f"| Host | `{host}` (RTX 4000 Ada) |",
        f"| Model dir | `{data.get('model_dir')}` |",
        f"| sherpa-onnx | {api.get('sherpa_onnx_version', '?')} |",
        f"| Provider requested | `{data.get('provider_requested')}` |",
        f"| Provider effective | `{data.get('provider_effective')}` |",
        f"| Speaker id | {data.get('sid')} (af_heart if 0) |",
        f"| Sample rate | {sr} Hz |",
        "",
        "### Metrics (raw)",
        "",
        "| mode | n | RTF mean | RTF p50 | TTFC ms mean | TTFC ms p50 | "
        "TTFC ms min | synth_sec mean | multi-callback? |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---|",
    ]
    for mode, s in summaries.items():
        lines.append(
            "| {mode} | {n} | {rtf_mean} | {rtf_p50} | {ttfc_ms_mean} | {ttfc_ms_p50} | "
            "{ttfc_ms_min} | {synth_sec_mean} | {streaming} |".format(
                mode=mode,
                n=s.get("n", ""),
                rtf_mean=s.get("rtf_mean", ""),
                rtf_p50=s.get("rtf_p50", ""),
                ttfc_ms_mean=s.get("ttfc_ms_mean", ""),
                ttfc_ms_p50=s.get("ttfc_ms_p50", ""),
                ttfc_ms_min=s.get("ttfc_ms_min", ""),
                synth_sec_mean=s.get("synth_sec_mean", ""),
                streaming="yes" if s.get("streaming_callbacks_observed") else "no",
            )
        )
    lines += [
        "",
        "### TTS.0.2 streaming (from installed API + empirical)",
        "",
        api.get("finding", "(missing)"),
        "",
        f"- `generate_doc_mentions_callback`: {api.get('generate_doc_mentions_callback')}",
        f"- `OfflineTts` methods: `{methods}`",
        "",
        "*Do not treat these numbers as product SLOs until TTS.0.3 voice pick and "
        "TTS.0.4 sample-rate decision land in ADR 0008.*",
        "",
        "**Note:** Ada `venv-tts` sherpa-onnx ORT has **no CUDA EP** "
        "(`Please compile with -DSHERPA_ONNX_ENABLE_GPU=ON`); `provider=cuda` falls "
        "back to CPU. Contended mode storms CPAI detection; Kokoro itself stayed on CPU "
        "so VRAM (~15.7 GiB) is CPAI/other, not TTS.",
        "",
    ]

    text = args.baselines.read_text() if args.baselines.is_file() else ""
    pat = re.compile(
        r"\n## 12\. Kokoro TTS on Ada \(TTS\.0\).*?(?=\n## |\Z)", re.S
    )
    block = "\n".join(lines)
    if pat.search(text):
        text = pat.sub("\n" + block.strip() + "\n\n", text)
    else:
        if text and not text.endswith("\n"):
            text += "\n"
        text += block
    args.baselines.write_text(text)
    print(f"updated {args.baselines}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
