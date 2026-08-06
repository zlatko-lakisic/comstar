#!/usr/bin/env python3
"""Smoke tests for ldap_mcp tool dispatch (no live LDAP required)."""

from __future__ import annotations

import json
import unittest
from unittest.mock import patch

from ldap_mcp.server import TOOLS, dispatch_rpc, handle_tool


class LdapMcpTests(unittest.TestCase):
    def test_tools_list(self) -> None:
        names = {t["name"] for t in TOOLS}
        self.assertEqual(names, {"lookup_user", "list_comstar_users"})

    def test_lookup_missing_uid(self) -> None:
        out = handle_tool("lookup_user", {})
        self.assertFalse(out["ok"])

    def test_lookup_ok(self) -> None:
        fake = {"uid": "zlatko", "displayName": "Zlatko", "groups": []}
        with patch("ldap_mcp.server._get_json", return_value=(fake, None, 200)):
            out = handle_tool("lookup_user", {"uid": "zlatko"})
        self.assertTrue(out["ok"])
        self.assertTrue(out["found"])
        self.assertEqual(out["user"]["uid"], "zlatko")

    def test_initialize_rpc(self) -> None:
        resp = dispatch_rpc({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        assert resp is not None
        self.assertEqual(resp["result"]["serverInfo"]["name"], "comstar-ldap")
        listed = dispatch_rpc({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        assert listed is not None
        tools = listed["result"]["tools"]
        self.assertEqual(len(tools), 2)


if __name__ == "__main__":
    unittest.main()
