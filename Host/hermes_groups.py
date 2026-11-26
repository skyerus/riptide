"""Relay Riptide's group chat commands to the paired local Hermes gateway."""

import asyncio
import json
import sys
from urllib.parse import urlunsplit

import websockets

from hermes_screen import ScreenError, attach


MAX_REQUEST = 512 * 1024
MAX_REPLY = 2 * 1024 * 1024
METHODS = {
    "profiles.list": {"include_sessions"},
    "groups.capabilities": set(),
    "groups.list": {"limit", "offset"},
    "groups.create": {"room_id", "name", "members"},
    "groups.state": {"room_id"},
    "groups.log": {"room_id", "since_seq", "limit"},
    "groups.send": {"room_id", "event_id", "payload"},
    "groups.stop": {"room_id", "cancel_id"},
    "groups.continue": {"room_id", "discussion_event_id"},
    "groups.rename": {"room_id", "event_id", "name"},
    "groups.disband": {"room_id", "cancel_id"},
    "groups.retry": {"room_id", "member_id", "task_id", "execution_generation"},
    "groups.approve": {"room_id", "member_id", "task_id", "execution_generation", "request_id", "choice"},
}


def admitted(request):
    if not isinstance(request, dict) or set(request) != {"jsonrpc", "id", "method", "params"}:
        return False
    method, params = request["method"], request["params"]
    if (request["jsonrpc"] != "2.0" or not isinstance(request["id"], str) or not isinstance(method, str)
            or method not in METHODS or not isinstance(params, dict) or set(params) != METHODS[method]):
        return False
    if method == "profiles.list":
        return params["include_sessions"] is False
    if method == "groups.create":
        members = params["members"]
        return isinstance(members, list) and 2 <= len(members) <= 6 and all(
            isinstance(member, dict) and {"member_id", "profile", "handle"} <= set(member)
            and set(member) <= {"member_id", "profile", "handle", "display_name"}
            and all(isinstance(value, str) for value in member.values()) for member in members
        )
    if method == "groups.send":
        payload = params["payload"]
        return (isinstance(payload, dict) and set(payload) == {"text", "thread_id"}
                and all(isinstance(value, str) for value in payload.values()))
    if method == "groups.approve":
        return params["choice"] in ("once", "deny")
    return True


def write(packet):
    encoded = json.dumps(packet, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode()
    if len(encoded) >= MAX_REPLY:
        raise ValueError("Group chat reply exceeded the SSH frame limit.")
    sys.stdout.buffer.write(encoded + b"\n")
    sys.stdout.buffer.flush()


async def relay(reader, gateway):
    while True:
        try:
            line = await asyncio.wait_for(reader.readline(), 45)
        except TimeoutError:
            return
        if not line:
            return
        packet = json.loads(line)
        if not admitted(packet):
            request_id = packet.get("id") if isinstance(packet, dict) else None
            write({"jsonrpc": "2.0", "id": request_id, "error": {
                "code": -32602, "message": "Request is outside this SSH pairing’s group chat scope.",
                "data": {"admitted": False},
            }})
            continue
        await gateway.send(json.dumps(packet, allow_nan=False))
        async with asyncio.timeout(24):
            while True:
                reply = json.loads(await gateway.recv())
                if isinstance(reply, dict) and reply.get("id") == packet["id"] and "method" not in reply:
                    write(reply)
                    break


async def serve(hermes, home):
    reader = asyncio.StreamReader(limit=MAX_REQUEST)
    loop = asyncio.get_running_loop()
    stdin, _ = await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer)
    try:
        endpoint, protocols = await attach(hermes, home)
        async with websockets.connect(urlunsplit(endpoint), subprotocols=protocols,
                                      open_timeout=8, close_timeout=2, max_size=MAX_REPLY) as gateway:
            if gateway.subprotocol != protocols[0]:
                raise ScreenError("Hermes did not accept the local gateway connection.")
            await relay(reader, gateway)
    finally:
        stdin.close()


if __name__ == "__main__":
    try:
        asyncio.run(serve(sys.argv[1], sys.argv[2]))
    except (OSError, ValueError, KeyError, TypeError, TimeoutError, ScreenError, websockets.exceptions.WebSocketException):
        sys.exit(1)
