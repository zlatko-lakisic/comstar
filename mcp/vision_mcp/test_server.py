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
            {"who_is_present", "describe_view", "check_camera"},
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


if __name__ == "__main__":
    unittest.main()
