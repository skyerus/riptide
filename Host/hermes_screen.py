#!/usr/bin/env python3
"""SSH adapter for Hermes's native Bot Screen, scoped to the paired profile."""

import asyncio
import base64
import json
import os
import sys
from urllib.parse import urlencode, urlsplit, urlunsplit

import websockets


MAX_LINE = 128 * 1024


class ScreenError(Exception):
    pass


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
    def __init__(self, gateway, endpoint):
        self.gateway = gateway
        self.endpoint = endpoint
        self.request_id = 0
        self.viewer = None
        self.stream = None

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
                report("control", held=result["lease"]["holder"] == "human")
            elif command == {"command": "release"}:
                result = await self.call("display.lease.release", viewer_id=self.viewer)
                report("released", in_use=result["lease"]["holder"] == "human")
            else:
                raise ScreenError("Riptide sent an unsupported screen command.")


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
            display = Display(gateway, endpoint)
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
