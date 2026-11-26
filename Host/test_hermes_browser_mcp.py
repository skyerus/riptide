from types import SimpleNamespace
import unittest
from unittest.mock import Mock

from hermes_browser_mcp import HANDOFF, Chrome, tool_result


class ChromeComputerUseTests(unittest.TestCase):
    def setUp(self):
        self.state = SimpleNamespace(holder="agent", epoch=1)
        self.lease = Mock(AGENT="agent")
        self.lease.get.return_value = self.state
        self.native = Mock()
        self.native.handle_computer_use.return_value = '{"ok":true}'
        self.chrome = Chrome("/profile", self.lease, None, None, self.native, codex_reviewed_input=True)
        self.chrome.window = Mock(return_value=(":20", 33, 123))

    def test_capture_targets_the_observed_chrome_window_and_fences_each_input(self):
        self.assertIn("error", self.chrome.call("computer_use", {"action": "key", "keys": "ctrl+l"}, None))
        self.native.handle_computer_use.assert_not_called()
        self.assertTrue(self.chrome.call("computer_use", {"action": "capture"}, None)["ok"])
        self.native.handle_computer_use.assert_called_once_with(
            {"action": "capture", "app": "chrome", "mode": "vision", "window_id": 33, "pid": 123}, session_id="riptide_hermes_browser"
        )
        self.state.epoch += 2
        self.assertIn("error", self.chrome.call("chrome_input", {"action": "key", "keys": "ctrl+l"}, None))

    def test_human_lease_blocks_input_and_capture(self):
        self.state.holder = "human"
        for name, args in (("computer_use", {"action": "capture"}), ("chrome_input", {"action": "click", "element": 2})):
            self.assertEqual(self.chrome.call(name, args, None)["code"], "human_has_control")
        self.chrome.window.assert_not_called()
        self.native.handle_computer_use.assert_not_called()

    def test_reviewed_input_does_not_request_a_second_approval(self):
        self.chrome.call("computer_use", {"action": "capture"}, None)
        self.native.handle_computer_use.side_effect = lambda *_args, **_kwargs: (
            {"approved": self.native.set_approval_callback.call_args.args[0]("", "") == "once"}
        )
        elicit = Mock(side_effect=AssertionError("Chrome input must not ask for a second approval."))
        self.assertTrue(self.chrome.call("chrome_input", {"action": "key", "keys": "ctrl+l"}, elicit)["approved"])
        elicit.assert_not_called()
        self.assertEqual(self.native.handle_computer_use.call_args.args[0]["delivery_mode"], "foreground")

    def test_input_still_requires_the_captured_window_at_dispatch(self):
        self.chrome.call("computer_use", {"action": "capture"}, None)

        def native_input(*_args, **_kwargs):
            self.chrome.window.return_value = (":20", 34, 124)
            return {"approved": self.native.set_approval_callback.call_args.args[0]("", "") == "once"}

        self.native.handle_computer_use.side_effect = native_input
        self.assertFalse(self.chrome.call("chrome_input", {"action": "key", "keys": "ctrl+l"}, None)["approved"])

    def test_input_requires_the_codex_review_route(self):
        self.chrome.codex_reviewed_input = False
        reply = self.chrome.call("chrome_input", {"action": "key", "keys": "ctrl+l"}, None)
        self.assertIn("requires the paired Codex App Server approval route", reply["error"])
        self.native.handle_computer_use.assert_not_called()

    def test_handoff_requires_a_new_lease_epoch(self):
        reply = {"action": "accept", "content": {"browser": HANDOFF}}
        args = {"reason": "Sign in to the site."}
        self.assertIn("error", self.chrome.call("chrome_handoff", args, lambda form: reply))

        def hand_back(_form):
            self.state.epoch += 2
            return reply

        self.assertEqual(self.chrome.call("chrome_handoff", args, hand_back), {"status": "handed_back"})

    def test_screenshots_use_mcp_image_content(self):
        response = tool_result({"_multimodal": True, "content": [
            {"type": "text", "text": "Chrome"},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64,AA=="}},
        ]})
        self.assertEqual(response.content[1], {"type": "image", "mimeType": "image/png", "data": "AA=="})
