#!/usr/bin/env python3
"""Unit tests for comstar_memory_server path hardening."""

from __future__ import annotations

import importlib.util
import sys
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


class MemoryPathTest(unittest.TestCase):
    def setUp(self) -> None:
        self.mod = _load_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.mod.os.environ["COMSTAR_MEMORY_DIR"] = self.tmp.name

    def test_safe_userid_rejects_traversal(self) -> None:
        # Path separators are scrubbed to underscores — never used raw in joins.
        self.assertEqual(self.mod.safe_userid("../etc/passwd"), "___etc_passwd")
        self.assertIsNone(self.mod.safe_userid("guest"))
        self.assertEqual(self.mod.safe_userid("Zlatko"), "zlatko")
        path = self.mod.memory_path("___etc_passwd")
        self.assertEqual(path.parent.resolve(), Path(self.tmp.name).resolve())
        self.assertEqual(path.name, "___etc_passwd.json")

    def test_memory_path_stays_under_store(self) -> None:
        path = self.mod.memory_path("zlatko")
        self.assertEqual(path.parent.resolve(), Path(self.tmp.name).resolve())
        self.assertEqual(path.name, "zlatko.json")


if __name__ == "__main__":
    unittest.main()
