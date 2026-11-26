import asyncio
from hashlib import sha256
from pathlib import Path
import tempfile
import unittest
from unittest.mock import AsyncMock, Mock, patch

from hermes_screen import BrowserWindow, Display


class BrowserWindowTests(unittest.TestCase):
    def setUp(self):
        home = self.enterContext(tempfile.TemporaryDirectory())
        self.state = Path(home) / "bot-desktop"
        self.state.mkdir()
        (self.state / "Xauthority").touch()
        self.browser = BrowserWindow({
            "placement": "gateway", "display": ":99", "socket": str(self.state / "rfb.sock"),
        }, home)

    def test_cold_takeover_uses_the_profile_browser_launcher(self):
        panel = self.state / "xdg" / "xfce4" / "panel"
        launcher = panel / "launcher-22" / "hermes.desktop"
        launcher.parent.mkdir(parents=True)
        launcher.touch()
        (panel / ".hermes-browser-launcher").write_text("22\n")
        (self.state / "env").write_text("DISPLAY=:1\nDBUS_SESSION_BUS_ADDRESS=unix:path=/fixture/dbus\n")

        self.browser.properties = Mock(return_value="")
        with patch("hermes_screen.subprocess.run") as run:
            self.browser.open_or_activate()

        self.assertEqual(run.call_args.args[0], ["gio", "launch", str(launcher)])
        self.assertEqual(run.call_args.kwargs["env"]["DISPLAY"], ":99")
        self.assertEqual(run.call_args.kwargs["env"]["XAUTHORITY"], str(self.state / "Xauthority"))
        self.assertEqual(run.call_args.kwargs["env"]["DBUS_SESSION_BUS_ADDRESS"], "unix:path=/fixture/dbus")

    def test_takeover_brings_forward_an_existing_browser(self):
        self.browser.properties = Mock(side_effect=[
            "_NET_ACTIVE_WINDOW(WINDOW): window id # 0x1",
            'WM_CLASS(STRING) = "terminal", "Xfce4-terminal"',
            "_NET_CLIENT_LIST_STACKING(WINDOW): window id # 0x2, 0x1",
            'WM_CLASS(STRING) = "terminal", "Xfce4-terminal"',
            'WM_CLASS(STRING) = "chrome", "Chrome-for-Testing"',
        ])
        self.browser.send_window_message = Mock()

        self.browser.open_or_activate()

        self.browser.send_window_message.assert_called_once_with(2, "_NET_ACTIVE_WINDOW", 2)

    def test_chrome_mapped_after_launch_is_activated_before_measuring(self):
        self.browser.properties = Mock(side_effect=[
            "_NET_ACTIVE_WINDOW(WINDOW): window id # 0x0, 0x0",
            "_NET_CLIENT_LIST_STACKING(WINDOW): window id # 0x2",
            'WM_CLASS(STRING) = "chrome", "Google-chrome"',
            "_NET_ACTIVE_WINDOW(WINDOW): window id # 0x2",
            'WM_CLASS(STRING) = "chrome", "Google-chrome"\nminimum size: 500 by 350',
        ])
        self.browser.send_window_message = Mock(return_value=True)

        self.assertIsNone(self.browser.minimum_width(activate=True))
        self.browser.send_window_message.assert_called_once_with(2, "_NET_ACTIVE_WINDOW", 2)
        self.assertEqual(self.browser.minimum_width(activate=True), 512)


class DisplayTests(unittest.IsolatedAsyncioTestCase):
    async def test_takeover_prepares_a_browser_only_with_the_owning_lease(self):
        display = Display(None, None, "/fixture")
        display.viewer = "phone"
        display.browser = Mock(env={"DISPLAY": ":99"})
        display.prepare_browser = AsyncMock(return_value=512)

        for owner in ("other-phone", "phone"):
            with self.subTest(owner=owner), patch("hermes_screen.report") as report:
                display.call = AsyncMock(return_value={"lease": {
                    "holder": "human", "viewer_hash": sha256(owner.encode()).hexdigest()[:12],
                }})
                reader = asyncio.StreamReader()
                reader.feed_data(b'{"command":"acquire"}\n')
                reader.feed_eof()

                await display.input(reader)

                owns_lease = owner == "phone"
                report.assert_called_once_with("control", held=owns_lease, in_use=True,
                                               minimum_browser_width=512 if owns_lease else None)
        display.prepare_browser.assert_awaited_once()
