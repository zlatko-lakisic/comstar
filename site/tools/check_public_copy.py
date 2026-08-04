#!/usr/bin/env python3
"""Warn if internal jargon or em dashes leak into the built product page."""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HTML = ROOT / "site" / "dist" / "index.html"

# Allowed once: the agentic-orchestration project name in link text.
ALLOW_SUBSTRINGS = (
    "agentic-orchestration",
    "agentic-orchestration-reach",
)

PATTERNS = [
    (re.compile(r"\bM[0-9]\b"), "milestone code (M0-M9)"),
    (re.compile(r"\bADR\b"), "ADR reference"),
    (re.compile(r"\bUAT\b"), "UAT acronym"),
    (re.compile(r"\bAda\b"), "Ada codename"),
    (re.compile(r"\bCPAI\b"), "CPAI acronym"),
    (re.compile(r"\bAO "), "AO shorthand"),
    (re.compile(r"[—–]"), "em/en dash"),
]


def scrubbed(text: str) -> str:
    out = text
    for s in ALLOW_SUBSTRINGS:
        out = out.replace(s, "")
    return out


def main() -> int:
    if not HTML.is_file():
        print(f"::warning::Missing {HTML}; run npm run build first")
        return 0
    text = scrubbed(HTML.read_text(encoding="utf-8", errors="replace"))
    warnings: list[str] = []
    for pattern, label in PATTERNS:
        for m in pattern.finditer(text):
            start = max(0, m.start() - 40)
            end = min(len(text), m.end() + 40)
            snippet = re.sub(r"\s+", " ", text[start:end]).strip()
            warnings.append(f"{label}: ...{snippet}...")
    if warnings:
        print(f"::warning::Public copy check found {len(warnings)} issue(s)")
        for w in warnings:
            print(f"::warning::{w}")
        # Warn-level: do not fail the build.
        return 0
    print("Public copy check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
