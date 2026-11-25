"""Lease-scoped mobile emulation for the Chromium profile in Hermes Bot Screen."""

import asyncio
from collections import deque
import contextlib
import json
import re

import websockets


class DevToolsError(Exception):
    pass


def debug_endpoint(profile):
    port, path = (profile / "DevToolsActivePort").read_text().splitlines()
    if not port.isascii() or not port.isdecimal() or not 0 < int(port) <= 65535 or not re.fullmatch(
        r"/devtools/browser/[0-9a-fA-F-]+", path
    ):
        raise DevToolsError("The Chrome debugging address is invalid.")
    return f"ws://127.0.0.1:{port}{path}"


class DevTools:
    def __init__(self, connection):
        self.connection = connection
        self.events = deque()
        self.sequence = 0

    async def call(self, method, params=None, *, session=None):
        self.sequence += 1
        request = {"id": self.sequence, "method": method, "params": params or {}}
        if session is not None:
            request["sessionId"] = session
        await self.connection.send(json.dumps(request))
        async with asyncio.timeout(2):
            while True:
                message = json.loads(await self.connection.recv())
                if message.get("id") == self.sequence:
                    if "error" in message:
                        raise DevToolsError(method)
                    return message["result"]
                if message.get("method") == "Target.attachedToTarget":
                    self.events.append(message)

    async def next_attachment(self):
        while not self.events:
            message = json.loads(await self.connection.recv())
            if message.get("method") == "Target.attachedToTarget":
                self.events.append(message)
        return self.events.popleft()["params"]


def mobile_identity(version):
    version_match = re.search(r"(?:Chrome|Chromium)/(\d+(?:\.\d+){3})", version["product"])
    if version_match is None:
        raise DevToolsError("The Chrome version is unavailable.")
    full = version_match[1]
    major = full.split(".")[0]
    brands = ("Chromium", "Google Chrome")
    return {
        "userAgent": ("Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 "
                      f"(KHTML, like Gecko) Chrome/{major}.0.0.0 Mobile Safari/537.36"),
        "platform": "Linux armv8l",
        "userAgentMetadata": {
            "brands": [{"brand": brand, "version": major} for brand in brands],
            "fullVersionList": [{"brand": brand, "version": full} for brand in brands],
            "mobile": True,
            "platform": "Android",
            "platformVersion": "14.0.0",
            "architecture": "",
            "model": "Pixel 7",
        },
    }


async def emulate_tab(cdp, target, identity):
    session = target["sessionId"]
    try:
        layout = await cdp.call("Page.getLayoutMetrics", session=session)
        viewport = layout["cssLayoutViewport"]
        width = 390  # CSS pixels for the emulated phone, independent of the X11 window minimum.
        scale = max(1, viewport["clientWidth"] / width)
        await cdp.call("Emulation.setDeviceMetricsOverride", {
            "width": width,
            "height": max(1, round(viewport["clientHeight"] / scale)),
            "deviceScaleFactor": 1,
            "mobile": True,
            "scale": scale,
            "dontSetVisibleSize": True,
        }, session=session)
        await cdp.call("Emulation.setTouchEmulationEnabled", {"enabled": True, "maxTouchPoints": 5},
                       session=session)
        await cdp.call("Emulation.setUserAgentOverride", identity, session=session)
    finally:
        if target["waitingForDebugger"]:
            with contextlib.suppress(DevToolsError):
                await cdp.call("Runtime.runIfWaitingForDebugger", session=session)


class MobileView:
    """A private DevTools attachment. Closing it resets emulation on the same tabs."""

    def __init__(self):
        self.task = None

    async def start(self, pid, profile):
        await self.close()
        ready = asyncio.get_running_loop().create_future()
        self.task = asyncio.create_task(self.run(pid, profile, ready))
        try:
            async with asyncio.timeout(5):
                await ready
        except (OSError, UnicodeError, ValueError, KeyError, TimeoutError, DevToolsError,
                websockets.exceptions.WebSocketException):
            await self.close()
            return False
        return True

    async def run(self, pid, profile, ready):
        try:
            endpoint = await asyncio.to_thread(debug_endpoint, profile)
            async with websockets.connect(endpoint, open_timeout=2, close_timeout=1, max_size=2**20) as connection:
                cdp = DevTools(connection)
                info = await cdp.call("SystemInfo.getProcessInfo")
                if not any(proc["type"] == "browser" and proc["id"] == pid for proc in info["processInfo"]):
                    raise DevToolsError("The debugging socket did not match the paired Chromium window.")
                identity = mobile_identity(await cdp.call("Browser.getVersion"))
                await cdp.call("Target.setAutoAttach", {
                    "autoAttach": True,
                    "flatten": True,
                    "waitForDebuggerOnStart": True,
                    "filter": [{"type": "page"}, {"exclude": True}],
                })
                # Chrome announces existing page attachments in the auto-attach response sequence.
                if not cdp.events:
                    raise DevToolsError("Chromium returned no open tabs.")
                while cdp.events:
                    await emulate_tab(cdp, await cdp.next_attachment(), identity)
                if not ready.done():
                    ready.set_result(None)
                while True:
                    target = await cdp.next_attachment()
                    with contextlib.suppress(DevToolsError):
                        # A tab can close before it has finished attaching.
                        await emulate_tab(cdp, target, identity)
        except (OSError, UnicodeError, ValueError, KeyError, TimeoutError, DevToolsError,
                websockets.exceptions.WebSocketException) as error:
            if not ready.done():
                ready.set_exception(error)

    async def close(self):
        if self.task is not None:
            self.task.cancel()
            await asyncio.gather(self.task, return_exceptions=True)
            self.task = None
