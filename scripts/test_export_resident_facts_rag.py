#!/usr/bin/env python3
"""Tests for export_resident_facts_rag (fixture facts → pack manifest)."""

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
EXPORT = ROOT / "export_resident_facts_rag.py"


def _load():
    spec = importlib.util.spec_from_file_location("export_rag", EXPORT)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


class ExportResidentFactsTest(unittest.TestCase):
    def test_curated_filter(self) -> None:
        mod = _load()
        self.assertTrue(mod.is_curated("Resident prefers Assam tea", "preference"))
        self.assertFalse(mod.is_curated("Do not know the answer", "preference"))
        self.assertFalse(
            mod.is_curated(
                "Here are some headlines from around the world today about BBC",
                "note",
            )
        )
        self.assertFalse(mod.is_curated("Good morning — welcome back", "note"))

    def test_export_fixture_pack(self) -> None:
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
                ("tea", "zlatko", "preference", "Resident prefers Assam tea", now),
                ("junk", "zlatko", "preference", "Do not know what happened", now),
                (
                    "news",
                    "zlatko",
                    "note",
                    "Headlines from around the world today on BBC",
                    now,
                ),
            ]
            for fid, uid, kind, text, ts in rows:
                conn.execute(
                    "INSERT INTO facts VALUES (?,?,?,?,?,?,?)",
                    (fid, uid, kind, text, "test", ts, ts),
                )
            conn.commit()
            conn.close()

            out = Path(tmp) / "pack"
            proc = subprocess.run(
                [
                    sys.executable,
                    str(EXPORT),
                    "--db",
                    str(db),
                    "--out",
                    str(out),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            data = json.loads(proc.stdout)
            self.assertTrue(data["ok"])
            self.assertEqual(data["fact_count"], 1)
            manifest = json.loads((out / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["pack_id"], "comstar_resident_facts")
            self.assertEqual(manifest["fact_count"], 1)
            self.assertEqual(manifest["facts"][0]["id"], "tea")
            body = (out / "zlatko.md").read_text(encoding="utf-8")
            self.assertIn("Assam tea", body)
            self.assertNotIn("Do not know", body)
            self.assertNotIn("headlines", body.lower())

    def test_dry_run_empty_fails_without_allow(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "comstar_memory.sqlite3"
            conn = sqlite3.connect(str(db))
            conn.execute(
                "CREATE TABLE facts (id TEXT, userid TEXT, kind TEXT, text TEXT, "
                "source TEXT, created_ms INT, updated_ms INT)"
            )
            conn.commit()
            conn.close()
            proc = subprocess.run(
                [sys.executable, str(EXPORT), "--db", str(db), "--dry-run"],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(proc.returncode, 0)
            data = json.loads(proc.stdout)
            self.assertFalse(data["ok"])


if __name__ == "__main__":
    unittest.main()
