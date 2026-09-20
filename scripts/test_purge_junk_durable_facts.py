#!/usr/bin/env python3
"""Tests for purge_junk_durable_facts (dry-run on fixture SQLite)."""

from __future__ import annotations

import importlib.util
import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PURGE = ROOT / "purge_junk_durable_facts.py"


def _load_purge():
    spec = importlib.util.spec_from_file_location("purge_junk", PURGE)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


class PurgeJunkFactsTest(unittest.TestCase):
    def test_is_junk_heuristics(self) -> None:
        mod = _load_purge()
        self.assertTrue(mod.is_junk_fact("Do not know the answer"))
        self.assertTrue(mod.is_junk_fact("I don't hear you"))
        self.assertTrue(mod.is_junk_fact("Awaiting your voice"))
        self.assertFalse(mod.is_junk_fact("Resident prefers Assam tea"))
        self.assertFalse(
            mod.is_junk_fact("Remember that kitchen lights stay dim after 10pm")
        )

    def test_dry_run_fixture_sqlite(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "comstar_memory.sqlite3"
            conn = sqlite3.connect(str(db))
            conn.execute(
                """
                CREATE TABLE facts (
                  id TEXT PRIMARY KEY,
                  userid TEXT NOT NULL,
                  kind TEXT NOT NULL,
                  text TEXT NOT NULL,
                  source TEXT,
                  created_ms INTEGER NOT NULL,
                  updated_ms INTEGER NOT NULL
                )
                """
            )
            now = 1_700_000_000_000
            rows = [
                ("good-tea", "zlatko", "preference", "Resident prefers Assam tea"),
                ("junk-know", "zlatko", "preference", "Do not know what happened"),
                ("junk-hear", "zlatko", "note", "I don't hear you clearly"),
            ]
            for fid, uid, kind, text in rows:
                conn.execute(
                    "INSERT INTO facts VALUES (?,?,?,?,?,?,?)",
                    (fid, uid, kind, text, "test", now, now),
                )
            conn.commit()
            conn.close()

            proc = subprocess.run(
                [sys.executable, str(PURGE), "--db", str(db), "--dry-run"],
                check=True,
                capture_output=True,
                text=True,
            )
            data = json.loads(proc.stdout)
            self.assertTrue(data["ok"])
            self.assertTrue(data["dry_run"])
            self.assertEqual(data["deleted"], 0)
            ids = {j["id"] for j in data["junk"]}
            self.assertEqual(ids, {"junk-know", "junk-hear"})
            self.assertEqual(data["junk_count"], 2)

            conn = sqlite3.connect(str(db))
            n = conn.execute("SELECT COUNT(*) FROM facts").fetchone()[0]
            conn.close()
            self.assertEqual(n, 3)


if __name__ == "__main__":
    unittest.main()
