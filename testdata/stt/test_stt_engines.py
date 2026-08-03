"""STT-only tests (no TTS).

Offline tests always run. The live consistency gate is intentionally strict:
replaying a parecord golden 10× is NOT a pass — see bench_stt.py docstring.
"""

from __future__ import annotations

import json
import os
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import bench_stt  # noqa: E402

EXPECTED = "How are you doing today"


class SttFixtureOfflineTest(unittest.TestCase):
    def test_golden_transcript_documented(self) -> None:
        meta = json.loads((ROOT / "haydt-20260802-210836.json").read_text())
        self.assertEqual(meta["transcript"], EXPECTED)
        self.assertEqual(meta["source"], "parecord")

    def test_parecord_fixture_is_not_live_bridge(self) -> None:
        fix = bench_stt.Fixture.load(ROOT / "haydt-20260802-210836.json")
        self.assertFalse(
            fix.is_live_bridge,
            "parecord golden must not count as live bridge audio",
        )

    def test_normalize_match(self) -> None:
        self.assertTrue(
            bench_stt.transcripts_match("How are you doing today?", EXPECTED)
        )
        self.assertFalse(bench_stt.transcripts_match("", EXPECTED))
        self.assertFalse(
            bench_stt.transcripts_match(
                "Okay, thank you. We'll see you in the next one.", EXPECTED
            )
        )

    def test_require_live_gate_fails_without_bridge_fixtures(self) -> None:
        """Correct testing: no live corpus ⇒ gate must refuse to crown a winner."""
        live = bench_stt.load_fixtures(live_only=True)
        # Until we label real bridge captures, this must be empty or incomplete.
        # The bench CLI exits 3 when --require-live N cannot be met.
        self.assertLess(
            len(live),
            10,
            "if you add 10 live fixtures, update this expectation",
        )


@unittest.skipUnless(
    os.environ.get("COMSTAR_STT_BENCH") == "1",
    "set COMSTAR_STT_BENCH=1 to run live STT consistency bench",
)
class SttLiveBridgeBenchTest(unittest.TestCase):
    def test_engine_perfect_on_ten_live_bridge_fixtures(self) -> None:
        live = bench_stt.load_fixtures(live_only=True)
        self.assertGreaterEqual(
            len(live),
            10,
            msg=(
                "Need ≥10 labeled LIVE fixtures "
                '(JSON source=bridge path="audio→bridge→stt"). '
                "Capture through COMSTAR Listening, not parecord."
            ),
        )
        engines = bench_stt.discover_engines(["http_local", "fw_tiny", "fw_base"])
        results = bench_stt.run_trials(engines, live, trials=1)
        rows = bench_stt.summarize(results, trials=1)
        by_engine: dict[str, list[dict]] = {}
        for r in rows:
            by_engine.setdefault(r["engine"], []).append(r)
        winners = [
            eng
            for eng, erows in by_engine.items()
            if len(erows) >= 10 and all(x["perfect"] for x in erows)
        ]
        self.assertTrue(
            winners,
            msg="no engine scored perfect on all live fixtures: "
            + json.dumps(rows, indent=2),
        )


if __name__ == "__main__":
    unittest.main()
