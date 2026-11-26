from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, Mock

from hermes_browser_mcp import Chrome, HANDOFF_COMPLETE, HumanControl, ScreenError
from hermes_mobile import DevTools


TAB = "a" * 32


class ChromeTests(unittest.TestCase):
    def setUp(self):
        self.lease = Mock(AGENT="agent")
        self.lease.get.return_value = SimpleNamespace(holder="agent", epoch=8)
        self.desktop = Mock()
        self.chrome = Chrome(Path("/fixture"), self.lease, self.desktop, Mock(), Mock(return_value=None))

    def test_human_control_blocks_page_access_before_starting_chrome(self):
        self.lease.get.return_value = SimpleNamespace(holder="human", epoch=9)
        reply = self.chrome.call("chrome_snapshot", {"tab": TAB}, None)
        self.assertEqual(reply["code"], "human_has_control")
        self.desktop.ensure_started_for_tool.assert_not_called()

    def test_handoff_requires_the_user_to_release_the_screen(self):
        self.chrome.perform = AsyncMock(return_value=("example.test", 8))
        reply = {"action": "accept", "content": {"browser": HANDOFF_COMPLETE}}
        args = {"tab": TAB, "reason": "sign in"}
        self.assertIn("error", self.chrome.call("chrome_handoff", args, lambda _: reply))

        self.chrome.snapshots[TAB] = (8, "https://example.test", [])
        self.lease.get.return_value = SimpleNamespace(holder="agent", epoch=10)
        ask = Mock(return_value=reply)
        self.assertEqual(self.chrome.call("chrome_handoff", args, ask), {"tab": TAB, "status": "handed_back"})
        self.assertEqual(ask.call_args.args[0]["requestedSchema"]["properties"]["browser"]["enum"],
                         [HANDOFF_COMPLETE])
        self.assertNotIn(TAB, self.chrome.snapshots)

    def test_rejects_internal_pages_and_malformed_tab_ids_without_a_browser(self):
        self.assertIn("error", self.chrome.call("chrome_open", {"url": "file:///etc/passwd"}, None))
        self.assertIn("error", self.chrome.call("chrome_snapshot", {"tab": "a tab"}, None))
        self.desktop.ensure_started_for_tool.assert_not_called()


class ChromeActionTests(unittest.IsolatedAsyncioTestCase):
    async def test_takeover_discards_an_in_flight_devtools_reply(self):
        socket = AsyncMock()
        socket.recv.return_value = '{"id":1,"result":{"text":"page"}}'
        check = Mock(side_effect=[None, HumanControl("User took over")])
        with self.assertRaises(HumanControl):
            await DevTools(socket, check).call("Runtime.evaluate")
        socket.send.assert_awaited_once()

    async def test_control_reference_expires_after_handoff(self):
        chrome = Chrome(Path("/fixture"), Mock(), Mock(), Mock(), Mock())
        chrome.snapshots[TAB] = (8, "https://example.test", [{}])
        peer = AsyncMock()
        with self.assertRaisesRegex(ScreenError, "fresh snapshot"):
            await chrome.page(peer, "session", TAB, 10, "chrome_click", {"ref": 1})
        peer.call.assert_not_awaited()
