import base64
import unittest
from unittest.mock import patch

from vision_mcp import server


class VisionMcpTest(unittest.TestCase):
    def test_tools_list_matches_contract(self) -> None:
        response = server.dispatch_rpc(
            {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}
        )

        self.assertIsNotNone(response)
        names = {tool["name"] for tool in response["result"]["tools"]}
        self.assertEqual(
            names,
            {
                "who_is_present",
                "describe_view",
                "check_camera",
                "list_person_visits",
                "describe_visit",
                "who_visited",
                "person_last_seen",
            },
        )

    def test_who_is_present_filters_unknown_and_low_confidence(self) -> None:
        args = {"image_b64": base64.b64encode(b"jpeg").decode("ascii")}
        payload = {
            "success": True,
            "predictions": [
                {"userid": "zlatko", "confidence": 0.91},
                {"userid": "unknown", "confidence": 0.99},
                {"userid": "other", "confidence": 0.1},
            ],
        }

        with patch.object(server, "_cpai_multipart", return_value=payload):
            result = server.handle_tool("who_is_present", args)

        self.assertEqual(
            result,
            {
                "ok": True,
                "people": [{"userid": "zlatko", "confidence": 0.91}],
                "count": 1,
            },
        )

    def test_describe_view_filters_low_confidence(self) -> None:
        args = {"image_b64": base64.b64encode(b"jpeg").decode("ascii")}
        payload = {
            "success": True,
            "predictions": [
                {"label": "person", "confidence": 0.93},
                {"label": "chair", "confidence": 0.2},
            ],
        }

        with patch.object(server, "_cpai_multipart", return_value=payload):
            result = server.handle_tool("describe_view", args)

        self.assertEqual(
            result,
            {
                "ok": True,
                "objects": [{"label": "person", "confidence": 0.93}],
            },
        )

    def test_missing_frame_source_is_an_error(self) -> None:
        with (
            patch.object(server, "FRAME_URL", ""),
            patch.object(server, "FRAME_PATH", ""),
        ):
            result = server.handle_tool("who_is_present", {})

        self.assertFalse(result["ok"])
        self.assertIn("no_frame_source", result["error"])

    def test_list_person_visits_normalizes_frigate_events(self) -> None:
        events = [
            {
                "id": "e1",
                "camera": "driveway",
                "label": "person",
                "start_time": 1_700_000_000.0,
                "end_time": 1_700_000_010.0,
                "has_snapshot": True,
                "sub_label": "Zlatko Lakisic",
                "data": {"top_score": 0.9},
            },
            {
                "id": "e2",
                "camera": "driveway",
                "label": "person",
                "start_time": 1_700_000_100.0,
                "end_time": None,
                "has_snapshot": True,
                "sub_label": None,
                "data": {"score": 0.8},
            },
        ]
        with patch.object(server, "_frigate_events", return_value=events):
            result = server.handle_tool(
                "list_person_visits",
                {"camera": "driveway", "since": 1_700_000_000},
            )

        self.assertTrue(result["ok"])
        self.assertEqual(result["count"], 2)
        self.assertEqual(result["visits"][0]["name"], "Zlatko Lakisic")
        self.assertIsNone(result["visits"][1]["name"])

    def test_describe_visit_skips_llm_when_named(self) -> None:
        ev = {
            "id": "e1",
            "camera": "driveway",
            "label": "person",
            "start_time": 1_700_000_000.0,
            "has_snapshot": True,
            "sub_label": "Zlatko Lakisic",
        }
        with patch.object(server, "_frigate_event", return_value=ev):
            result = server.handle_tool("describe_visit", {"event_id": "e1"})

        self.assertTrue(result["ok"])
        self.assertTrue(result["recognized"])
        self.assertIn("Zlatko", result["description"])

    def test_who_visited_summarizes_named_and_describes_unknown(self) -> None:
        events = [
            {
                "id": "named",
                "camera": "driveway",
                "label": "person",
                "start_time": 1_700_000_000.0,
                "has_snapshot": True,
                "sub_label": "Zlatko Lakisic",
                "data": {},
            },
            {
                "id": "unk",
                "camera": "driveway",
                "label": "person",
                "start_time": 1_700_000_200.0,
                "has_snapshot": True,
                "sub_label": None,
                "data": {},
            },
        ]

        def fake_describe(args: dict) -> dict:
            if args.get("event_id") == "unk":
                return {
                    "ok": True,
                    "event_id": "unk",
                    "name": None,
                    "description": "Person in a dark hoodie walking toward the garage.",
                    "when": "3:00 PM",
                    "recognized": False,
                    "backend": "test",
                }
            return server._describe_visit(args)

        with (
            patch.object(server, "_frigate_events", return_value=events),
            patch.object(server, "_describe_visit", side_effect=fake_describe),
        ):
            result = server.handle_tool(
                "who_visited", {"camera": "driveway", "since": 1_700_000_000}
            )

        self.assertTrue(result["ok"])
        self.assertEqual(result["recognized"][0]["name"], "Zlatko Lakisic")
        self.assertEqual(len(result["unknown"]), 1)
        self.assertIn("hoodie", result["spoken_hint"].lower())
        self.assertIn("Zlatko", result["spoken_hint"])

    def test_person_last_seen_matches_frigate_name_not_neighbors(self) -> None:
        events = [
            {
                "id": "z1",
                "camera": "driveway",
                "label": "person",
                "start_time": 1_700_000_500.0,
                "has_snapshot": True,
                "sub_label": "Zlatko Lakisic",
                "data": {},
            },
            {
                "id": "a1",
                "camera": "east_side",
                "label": "person",
                "start_time": 1_700_000_400.0,
                "has_snapshot": True,
                "sub_label": "Adna Lakisic",
                "data": {},
            },
        ]
        with patch.object(server, "_frigate_events", return_value=events):
            result = server.handle_tool(
                "person_last_seen", {"name": "Adna", "since": "30d"}
            )
        self.assertTrue(result["ok"])
        self.assertTrue(result["found"])
        self.assertEqual(result["matched_name"], "Adna Lakisic")
        self.assertEqual(result["last"]["camera"], "east_side")
        self.assertEqual(result["last"]["id"], "a1")
        self.assertIn("Adna Lakisic", result["spoken_hint"])
        self.assertIn("east side", result["spoken_hint"].lower())
        self.assertNotIn("driveway", result["spoken_hint"].lower())

    def test_person_last_seen_not_found(self) -> None:
        with patch.object(server, "_frigate_events", return_value=[]):
            result = server.handle_tool(
                "person_last_seen", {"name": "Nobody", "since": "7d"}
            )
        self.assertTrue(result["ok"])
        self.assertFalse(result["found"])
        self.assertIn("have not seen", result["spoken_hint"].lower())


if __name__ == "__main__":
    unittest.main()
