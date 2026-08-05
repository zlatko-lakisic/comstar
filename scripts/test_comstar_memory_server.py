#!/usr/bin/env python3
"""Unit tests for comstar_memory_server path + rolling storage."""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


def _load_module():
    path = Path(__file__).resolve().with_name("comstar_memory_server.py")
    spec = importlib.util.spec_from_file_location("comstar_memory_server", path)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


class MemoryServerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.mod = _load_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.mod.os.environ["COMSTAR_MEMORY_DIR"] = self.tmp.name

    def test_safe_userid(self) -> None:
        self.assertEqual(self.mod.safe_userid("../etc/passwd"), "___etc_passwd")
        self.assertIsNone(self.mod.safe_userid("guest"))
        self.assertEqual(self.mod.safe_userid("Zlatko"), "zlatko")

    def test_rolling_roundtrip_uses_sqlite_not_userid_path(self) -> None:
        put = self.mod.put_rolling("zlatko", {"turns": [{"role": "user", "text": "hi"}]})
        self.assertTrue(put["ok"])
        got = self.mod.get_rolling("zlatko")
        self.assertEqual(got["userid"], "zlatko")
        self.assertEqual(got["turns"][0]["text"], "hi")
        # No per-user JSON file should be created.
        self.assertFalse((Path(self.tmp.name) / "zlatko.json").exists())
        self.assertTrue((Path(self.tmp.name) / self.mod.DB_NAME).exists())

    def test_legacy_json_migrates_once(self) -> None:
        legacy = Path(self.tmp.name) / "zlatko.json"
        legacy.write_text(
            json.dumps({"userid": "zlatko", "turns": [{"role": "user", "text": "old"}]}),
            encoding="utf-8",
        )
        got = self.mod.get_rolling("zlatko")
        self.assertEqual(got["turns"][0]["text"], "old")


if __name__ == "__main__":
    unittest.main()
