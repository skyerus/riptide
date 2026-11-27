#!/usr/bin/env python3
"""SSH adapter for Hermes's native Bot Screen, scoped to the paired profile."""

import asyncio
import base64
from ctypes import CDLL, Structure, Union, byref, c_char_p, c_int, c_long, c_ulong, c_void_p
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from urllib.parse import urlencode, urlsplit, urlunsplit

import websockets


MAX_LINE = 128 * 1024


class ScreenError(Exception):
    pass


class XWindowMessage(Structure):
    _fields_ = [
        ("type", c_int), ("serial", c_ulong), ("send_event", c_int), ("display", c_void_p),
        ("window", c_ulong), ("message_type", c_ulong), ("format", c_int), ("data", c_long * 5),
    ]


class XEvent(Union):
    _fields_ = [("message", XWindowMessage), ("padding", c_long * 24)]


class BrowserWindow:
    STATES = ("_NET_WM_STATE_MAXIMIZED_HORZ", "_NET_WM_STATE_MAXIMIZED_VERT")
    CHROMIUM = {"chrome", "chrome-for-testing", "google-chrome", "google-chrome-beta",
                "chromium", "chromium-browser"}

    def __init__(self, view, home):
        self.window = None
        self.states = ()
        self.env = None
        display = view.get("display") or ""
        self.state = state = Path(home) / "bot-desktop"
        if (view.get("placement") == "gateway" and re.fullmatch(r":\d{1,5}", display)
                and view.get("socket") == str(state / "rfb.sock") and (state / "Xauthority").is_file()):
            self.env = {**os.environ, "DISPLAY": display, "XAUTHORITY": str(state / "Xauthority")}

    def properties(self, *args):
        return subprocess.run(["xprop", *args], env=self.env, capture_output=True, text=True,
                              check=True, timeout=1).stdout

    def browser_details(self, window):
        details = self.properties("-id", hex(window), "WM_CLASS", "_NET_WM_STATE", "WM_NORMAL_HINTS")
        classes = set(re.findall(r'"([^"]+)"', details.lower()))
        return details if classes & self.CHROMIUM else None

    def active_browser(self, *, activate=False):
        if self.env is None:
            return
        root = self.properties("-root", "_NET_ACTIVE_WINDOW")
        match = re.search(r"# (0x[0-9a-fA-F]+)", root)
        if match and (window := int(match[1], 16)) and (details := self.browser_details(window)):
            return window, details
        if activate:
            self.activate_existing()

    def minimum_width(self, *, activate=False):
        active = self.active_browser(activate=activate)
        if active is None:
            return None
        _, details = active
        minimum = re.search(r"minimum size: (\d+) by", details)
        # Chromium's minimum is for the client area. Leave room for the window frame.
        return int(minimum[1]) + 12 if minimum else 512

    def activate_existing(self):
        windows = self.properties("-root", "_NET_CLIENT_LIST_STACKING")
        for identifier in reversed(re.findall(r"0x[0-9a-fA-F]+", windows)):
            window = int(identifier, 16)
            try:
                details = self.browser_details(window)
            except subprocess.CalledProcessError:
                continue  # The window was closed after the list was read.
            if details:
                return self.send_window_message(window, "_NET_ACTIVE_WINDOW", 2)
        return False

    def open_or_activate(self):
        if self.active_browser() or self.activate_existing():
            return

        # Use the same Desktop Entry the Hermes dock uses. Its Exec line selects
        # the agent's Chromium executable, persistent profile, and launch flags.
        launcher = self.launcher()
        env = dict(self.env)
        for key, _, value in (line.partition("=") for line in (self.state / "env").read_text().splitlines()):
            if key in {"DBUS_SESSION_BUS_ADDRESS", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME"}:
                env[key] = value
        env.pop("WAYLAND_DISPLAY", None)
        env.update(GDK_BACKEND="x11", XDG_SESSION_TYPE="x11")
        subprocess.run(["gio", "launch", str(launcher)], env=env, stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=3)

    def launcher(self):
        panel = self.state / "xdg" / "xfce4" / "panel"
        marker = panel / ".hermes-browser-launcher"
        launcher_id = marker.read_text().strip() if marker.is_file() else ""
        if not re.fullmatch(r"\d{1,8}", launcher_id):
            raise ScreenError("Hermes has no browser launcher for this profile.")
        launcher = panel / f"launcher-{launcher_id}" / "hermes.desktop"
        if not launcher.is_file():
            raise ScreenError("Hermes has no browser launcher for this profile.")
        return launcher

    def process_id(self, window):
        property_value = self.properties("-id", hex(window), "_NET_WM_PID")
        match = re.fullmatch(r"_NET_WM_PID\(CARDINAL\) = (\d+)\s*", property_value)
        return int(match[1]) if match else None

    def capture_fits(self, window):
        def geometry(target):
            result = subprocess.run(["xwininfo", *target], env={**self.env, "LC_ALL": "C"},
                                    capture_output=True, text=True, check=True, timeout=1)
            fields = re.findall(r"^\s*(Absolute upper-left [XY]|Width|Height):\s*(-?\d+)\s*$",
                                result.stdout, re.MULTILINE)
            return {name: int(value) for name, value in fields}

        desktop = geometry(["-root"])
        client = geometry(["-id", hex(window)])
        left, top = client["Absolute upper-left X"], client["Absolute upper-left Y"]
        # XGetImage requires the entire client area to be inside the screen.
        return (0 <= left and left + client["Width"] <= desktop["Width"]
                and 0 <= top and top + client["Height"] <= desktop["Height"])

    def is_maximized(self):
        active = self.active_browser()
        return active is not None and ("_NET_WM_STATE_FULLSCREEN" in active[1]
                                       or all(state in active[1] for state in self.STATES))

    def maximize(self):
        if self.window is not None:
            return
        active = self.active_browser()
        if active is None:
            return
        window, details = active
        if "_NET_WM_STATE_FULLSCREEN" in details:
            return
        states = tuple(state for state in self.STATES if state not in details)
        if not states:
            # Reapply existing maximization after the portrait framebuffer is active.
            if self.set_state(window, self.STATES, enable=False):
                time.sleep(0.08)
                self.set_state(window, self.STATES, enable=True)
        elif self.set_state(window, states, enable=True):
            self.window, self.states = window, states

    def restore(self):
        if self.window is not None:
            self.set_state(self.window, self.states, enable=False)
            self.window = None

    def set_state(self, window, states, *, enable):
        return self.send_window_message(window, "_NET_WM_STATE", int(enable),
                                        states[0], states[1] if len(states) == 2 else 0, 2)

    def send_window_message(self, window, message, *data):
        # EWMH asks this profile's window manager to change its Chromium window.
        # Xlib reads XAUTHORITY from this adapter's environment.
        library = CDLL("libX11.so.6")
        library.XOpenDisplay.argtypes = [c_char_p]
        library.XOpenDisplay.restype = c_void_p
        library.XDefaultRootWindow.argtypes = [c_void_p]
        library.XDefaultRootWindow.restype = c_ulong
        library.XInternAtom.argtypes = [c_void_p, c_char_p, c_int]
        library.XInternAtom.restype = c_ulong
        library.XSendEvent.argtypes = [c_void_p, c_ulong, c_int, c_long, c_void_p]
        library.XCloseDisplay.argtypes = [c_void_p]
        old_authority = os.environ.get("XAUTHORITY")
        os.environ["XAUTHORITY"] = self.env["XAUTHORITY"]
        try:
            display = library.XOpenDisplay(self.env["DISPLAY"].encode())
        finally:
            if old_authority is None:
                os.environ.pop("XAUTHORITY", None)
            else:
                os.environ["XAUTHORITY"] = old_authority
        if not display:
            return False
        try:
            def atom(name):
                return library.XInternAtom(display, name.encode(), 0)

            event = XEvent(message=XWindowMessage(
                type=33, window=window, message_type=atom(message), format=32,
                data=(c_long * 5)(*(atom(item) if isinstance(item, str) else item for item in data)),
            ))
            return bool(library.XSendEvent(display, library.XDefaultRootWindow(display), 0,
                                           (1 << 20) | (1 << 19), byref(event)))
        finally:
            library.XCloseDisplay(display)


def report(event, **fields):
    print(json.dumps({"event": event, **fields}, separators=(",", ":")), flush=True)


async def attach(hermes, home):
    proc = await asyncio.create_subprocess_exec(
        hermes, "gateway", "attach", "--json",
        env={**os.environ, "HERMES_HOME": home}, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )
    try:
        output, _ = await asyncio.wait_for(proc.communicate(), timeout=10)
    except TimeoutError:
        proc.kill()
        await proc.wait()
        raise ScreenError("Hermes did not answer the screen request.") from None
    if proc.returncode:
        raise ScreenError("The Hermes gateway is unavailable for this profile.")
    info = json.loads(output)
    endpoint = urlsplit(info["url"])
    if (endpoint.scheme != "ws" or endpoint.hostname not in {"127.0.0.1", "::1"}
            or endpoint.username is not None or endpoint.path != "/api/ws"
            or endpoint.query or endpoint.fragment or info["endpoint"]["profile_id"] != home):
        raise ScreenError("Hermes did not return a local gateway for the paired profile.")
    return endpoint, info["protocols"]


class Display:
    def __init__(self, gateway, endpoint, home):
        self.gateway = gateway
        self.endpoint = endpoint
        self.request_id = 0
        self.viewer = None
        self.stream = None
        self.home = home
        self.browser = None

    async def call(self, method, **params):
        self.request_id += 1
        request_id = self.request_id
        await self.gateway.send(json.dumps({"jsonrpc": "2.0", "id": request_id,
                                            "method": method, "params": params}))
        async with asyncio.timeout(20):
            while True:
                reply = json.loads(await self.gateway.recv())
                if reply.get("id") == request_id:
                    break
        if "error" in reply:
            raise ScreenError("Hermes could not " + {
                "display.status": "check Bot Screen.", "display.start": "start Bot Screen.",
                "display.observe": "open the live view.", "display.lease.acquire": "give you control.",
                "display.lease.release": "return control to the agent.",
            }[method])
        return reply["result"]

    async def open(self):
        status = await self.call("display.status")
        if not status.get("running"):
            await self.call("display.start")
        view = await self.call("display.observe")
        self.viewer = view["viewer_id"]
        self.browser = BrowserWindow(view, self.home)
        url = urlunsplit(self.endpoint._replace(path="/api/display/ws",
                          query=urlencode({"display_ticket": view["ticket"]})))
        self.stream = await websockets.connect(url, open_timeout=8, close_timeout=2, max_size=MAX_LINE)
        report("opened", in_use=view["lease"]["holder"] == "human", browser_visible=await self.browser_visible())

    async def output(self):
        async for frame in self.stream:
            if not isinstance(frame, bytes):
                raise ScreenError("Hermes returned an unexpected screen frame.")
            report("frame", data=base64.b64encode(frame).decode("ascii"))

    async def input(self, reader):
        while line := await reader.readline():
            command = json.loads(line)
            if not isinstance(command, dict):
                raise ScreenError("Riptide sent an invalid screen command.")
            if command.get("command") == "frame" and set(command) == {"command", "data"}:
                await self.stream.send(base64.b64decode(command["data"], validate=True))
            elif command == {"command": "acquire"}:
                result = await self.call("display.lease.acquire", viewer_id=self.viewer)
                owns_lease = self.owns(result)
                width = await self.prepare_browser() if owns_lease and self.browser.env is not None else None
                report("control", held=owns_lease, in_use=result["lease"]["holder"] == "human",
                       minimum_browser_width=width)
            elif command == {"command": "fit"}:
                if self.browser.env is not None and self.owns(await self.call("display.status")):
                    await self.frame_browser(self.browser.maximize)
                    if not await self.wait_for_browser(self.browser.is_maximized, 2):
                        raise ScreenError("Hermes could not fit the browser to this screen.")
                    report("fitted")
            elif command == {"command": "release"}:
                await self.restore_browser()
                result = await self.call("display.lease.release", viewer_id=self.viewer)
                report("released", in_use=result["lease"]["holder"] == "human",
                       browser_visible=await self.browser_visible())
            else:
                raise ScreenError("Riptide sent an unsupported screen command.")

    async def browser_visible(self):
        # A terminal-hosted display does not expose its local window manager to the SSH adapter.
        if self.browser.env is not None:
            return await self.frame_browser(self.browser.minimum_width) is not None

    async def prepare_browser(self):
        try:
            await asyncio.to_thread(self.browser.open_or_activate)
        except (OSError, subprocess.SubprocessError):
            raise ScreenError("Hermes could not start or bring forward its browser.") from None
        width = await self.wait_for_browser(lambda: self.browser.minimum_width(activate=True), 10)
        if width is None:
            raise ScreenError("Hermes started its browser, but no browser window appeared.")
        if self.owns(await self.call("display.status")):
            return width
        raise ScreenError("Someone else took control of the Hermes screen.")

    async def wait_for_browser(self, operation, seconds):
        deadline = asyncio.get_running_loop().time() + seconds
        while asyncio.get_running_loop().time() < deadline:
            if value := await self.frame_browser(operation):
                return value
            await asyncio.sleep(0.1)

    def owns(self, result):
        lease = result["lease"]
        return lease["holder"] == "human" and lease.get("viewer_hash") == sha256(self.viewer.encode()).hexdigest()[:12]

    async def restore_browser(self):
        if self.browser.window is not None and self.owns(await self.call("display.status")):
            await self.frame_browser(self.browser.restore)

    @staticmethod
    async def frame_browser(operation):
        try:
            return await asyncio.to_thread(operation)
        except (OSError, subprocess.SubprocessError):
            return None


async def serve(hermes, home):
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader(limit=MAX_LINE)
    stdin, _ = await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer)
    try:
        if json.loads(await reader.readline() or b"null") != {"command": "open"}:
            return
        endpoint, protocols = await attach(hermes, home)
        async with websockets.connect(urlunsplit(endpoint), subprotocols=protocols,
                                      open_timeout=8, close_timeout=2) as gateway:
            if gateway.subprotocol != protocols[0]:
                raise ScreenError("Hermes did not accept the native gateway connection.")
            display = Display(gateway, endpoint, home)
            await display.open()
            try:
                pumps = [asyncio.create_task(display.input(reader)), asyncio.create_task(display.output())]
                done, pending = await asyncio.wait(pumps, return_when=asyncio.FIRST_COMPLETED)
                for task in pending:
                    task.cancel()
                await asyncio.gather(*pending, return_exceptions=True)
                for task in done:
                    task.result()
            finally:
                if display.browser.window is not None:
                    try:
                        async with asyncio.timeout(2):
                            await display.restore_browser()
                    except (ScreenError, TimeoutError, websockets.exceptions.ConnectionClosed):
                        pass
                await display.stream.close()
    finally:
        stdin.close()


if __name__ == "__main__":
    try:
        asyncio.run(serve(*sys.argv[1:]))
    except ScreenError as error:
        report("error", message=str(error))
    except websockets.exceptions.ConnectionClosed as error:
        report("error", message="Someone else took control of Bot Screen." if error.code == 4000
               else "The Hermes screen disconnected. Reopen it to reconnect.")
    except (OSError, ValueError, TypeError, KeyError, websockets.exceptions.WebSocketException):
        report("error", message="Could not connect to the native Hermes screen.")
