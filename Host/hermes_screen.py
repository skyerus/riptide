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
        state = Path(home) / "bot-desktop"
        if (view.get("placement") == "gateway" and re.fullmatch(r":\d{1,5}", display)
                and view.get("socket") == str(state / "rfb.sock") and (state / "Xauthority").is_file()):
            self.env = {**os.environ, "DISPLAY": display, "XAUTHORITY": str(state / "Xauthority")}

    def properties(self, *args):
        return subprocess.run(["xprop", *args], env=self.env, capture_output=True, text=True,
                              check=True, timeout=1).stdout

    def maximize(self):
        if self.env is None or self.window is not None:
            return
        root = self.properties("-root", "_NET_ACTIVE_WINDOW")
        match = re.search(r"# (0x[0-9a-fA-F]+)", root)
        if match is None or int(match[1], 16) == 0:
            return
        details = self.properties("-id", match[1], "WM_CLASS", "_NET_WM_STATE")
        classes = set(re.findall(r'"([^"]+)"', details.lower()))
        if not (classes & self.CHROMIUM) or "_NET_WM_STATE_FULLSCREEN" in details:
            return
        states = tuple(state for state in self.STATES if state not in details)
        if states and self.set_state(int(match[1], 16), states, enable=True):
            self.window, self.states = int(match[1], 16), states

    def restore(self):
        if self.window is not None:
            self.set_state(self.window, self.states, enable=False)
            self.window = None

    def set_state(self, window, states, *, enable):
        # EWMH asks the window manager to change the active Chromium window.
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

            state_atoms = [atom(name) for name in states]
            event = XEvent(message=XWindowMessage(
                type=33, window=window, message_type=atom("_NET_WM_STATE"), format=32,
                data=(c_long * 5)(int(enable), state_atoms[0], state_atoms[1] if len(state_atoms) == 2 else 0, 2),
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
        report("opened", in_use=view["lease"]["holder"] == "human")

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
                if self.owns(result):
                    await self.frame_browser(self.browser.maximize)
                report("control", held=result["lease"]["holder"] == "human")
            elif command == {"command": "release"}:
                await self.restore_browser()
                result = await self.call("display.lease.release", viewer_id=self.viewer)
                report("released", in_use=result["lease"]["holder"] == "human")
            else:
                raise ScreenError("Riptide sent an unsupported screen command.")

    def owns(self, result):
        lease = result["lease"]
        return lease["holder"] == "human" and lease.get("viewer_hash") == sha256(self.viewer.encode()).hexdigest()[:12]

    async def restore_browser(self):
        if self.browser.window is not None and self.owns(await self.call("display.status")):
            await self.frame_browser(self.browser.restore)

    @staticmethod
    async def frame_browser(operation):
        try:
            await asyncio.to_thread(operation)
        except (OSError, subprocess.SubprocessError):
            pass


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
