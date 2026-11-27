import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from hermes_browser_mcp import HANDOFF, Chrome, tool_result
from hermes_chrome_profile import SHARED_BROWSER, browser_route


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

    def test_capture_fits_a_window_clipped_by_the_framebuffer(self):
        self.chrome = Chrome("/profile", self.lease, Mock(), Mock(), self.native)
        self.chrome.placement.resolve.return_value.where = self.chrome.placement.GATEWAY
        self.chrome.desktop.status.return_value = SimpleNamespace(display=":20", socket="/socket")
        with patch("hermes_browser_mcp.BrowserWindow") as browser:
            window = browser.return_value
            window.active_browser.return_value = (33, "Chrome")
            window.process_id.return_value = 123
            window.capture_fits.side_effect = [False, True]
            self.assertTrue(self.chrome.call("computer_use", {"action": "capture"}, None)["ok"])
        window.set_state.assert_called_once_with(33, window.STATES, enable=True)
        self.assertEqual(window.capture_fits.call_count, 2)

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

    def test_shared_desktop_invalidates_capture_after_another_agent_acts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            home = root / "profiles" / "owner"
            home.mkdir(parents=True)
            (root / SHARED_BROWSER).write_text('{"owner":"owner","members":["owner","default"]}')
            self.chrome.shared = browser_route(root).shared
            self.assertEqual(self.chrome.shared.home, home)
            self.assertIsNone(browser_route(root / "profiles" / "excluded").shared)
            other = Chrome(home, self.lease, None, None, self.native, shared=browser_route(home).shared)
            other.window = self.chrome.window
            capture = {"action": "capture"}
            self.assertTrue(self.chrome.call("computer_use", capture, None)["ok"])
            self.assertTrue(other.call("computer_use", capture, None)["ok"])
            self.native.handle_computer_use.reset_mock()
            self.assertIn("Capture the Chrome window again", self.chrome.call(
                "chrome_input", {"action": "key", "keys": "ctrl+l"}, None)["error"])
            self.native.handle_computer_use.assert_not_called()
            with other.shared.turn():
                self.assertIn("Another agent", self.chrome.call("computer_use", capture, None)["error"])

    def test_route_status_distinguishes_isolated_and_shared_without_opening_chrome(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            paired, owner = (root / "profiles" / name for name in ("rack", "owner"))
            paired.mkdir(parents=True)
            owner.mkdir()
            policy = root / SHARED_BROWSER
            policy.write_text('{"owner":"owner","members":["owner"]}')
            self.chrome.paired_home = self.chrome.home = paired
            status = {"action": "status"}
            self.assertEqual(self.chrome.call("computer_use", status, None), {
                "status": "ready", "scope": "isolated", "paired_profile": "rack", "desktop_profile": "rack",
                "shared_desktop_configured": True,
            })
            policy.write_text('{"owner":"owner","members":["owner","rack"]}')
            self.assertEqual(self.chrome.call("computer_use", status, None)["status"], "reconnect_required")
            self.chrome.home = owner
            self.chrome.shared = browser_route(paired).shared
            self.assertEqual(self.chrome.call("computer_use", status, None), {
                "status": "ready", "scope": "shared", "paired_profile": "rack", "desktop_profile": "owner",
                "shared_desktop_configured": True,
            })
            self.chrome.window.assert_not_called()
            self.native.handle_computer_use.assert_not_called()

    def test_revoked_shared_policy_blocks_old_connector_before_browser_access(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            paired, owner = (root / "profiles" / name for name in ("rack", "owner"))
            paired.mkdir(parents=True)
            owner.mkdir()
            policy = root / SHARED_BROWSER
            policy.write_text('{"owner":"owner","members":["owner","rack"]}')
            self.chrome.paired_home, self.chrome.home = paired, owner
            self.chrome.shared = browser_route(paired).shared
            self.chrome.captured = "old capture"
            policy.write_text('{"owner":"owner","members":["owner"]}')
            self.assertEqual(self.chrome.call("computer_use", {"action": "capture"}, None)["code"],
                             "browser_route_changed")
            self.assertIsNone(self.chrome.captured)
            self.chrome.window.assert_not_called()

    def test_future_pairing_manifest_targets_discover_shared_chrome_and_can_be_revoked(self):
        root = Path(self.enterContext(tempfile.TemporaryDirectory())).resolve()
        paired, owner, excluded = (root / "profiles" / name for name in ("new-agent", "owner", "excluded"))
        for home in (paired, owner, excluded):
            home.mkdir(parents=True)
        manifest = root / "pairing.json"
        config = {"chrome": {"home": str(root)}, "targets": {}}
        manifest.write_text(json.dumps(config))
        (root / SHARED_BROWSER).write_text(json.dumps({
            "owner": "owner", "members": ["owner"], "pairing_manifest": str(manifest),
        }))
        self.chrome.paired_home = self.chrome.home = paired
        status = {"action": "status"}
        self.assertEqual(self.chrome.call("computer_use", status, None)["scope"], "isolated")

        config["targets"]["new-agent"] = {"name": "New Agent"}
        manifest.write_text(json.dumps(config))
        self.assertEqual(self.chrome.call("computer_use", status, None)["status"], "reconnect_required")
        self.chrome.shared, self.chrome.home = browser_route(paired).shared, owner
        self.assertEqual(self.chrome.call("computer_use", status, None), {
            "status": "ready", "scope": "shared", "paired_profile": "new-agent", "desktop_profile": "owner",
            "shared_desktop_configured": True,
        })
        self.assertIsNone(browser_route(excluded).shared)

        config["targets"].clear()
        manifest.write_text(json.dumps(config))
        self.assertEqual(self.chrome.call("computer_use", {"action": "capture"}, None)["code"], "browser_route_changed")
        self.assertEqual(browser_route(owner).shared.home, owner)
        self.chrome.window.assert_not_called()
        self.native.handle_computer_use.assert_not_called()

    def test_manifest_must_be_owner_controlled_and_belong_to_the_same_hermes_home(self):
        root = Path(self.enterContext(tempfile.TemporaryDirectory())).resolve()
        manifest = root / "pairing.json"
        manifest.write_text(json.dumps({"chrome": {"home": str(root / "elsewhere")}, "targets": {"default": {}}}))
        (root / "profiles" / "owner").mkdir(parents=True)
        (root / SHARED_BROWSER).write_text(json.dumps({
            "owner": "owner", "members": ["owner"], "pairing_manifest": str(manifest),
        }))
        with self.assertRaisesRegex(ValueError, "Chrome-enabled pairing manifest"):
            browser_route(root)
        manifest.chmod(0o666)
        with self.assertRaisesRegex(ValueError, "owner-controlled file"):
            browser_route(root)

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
