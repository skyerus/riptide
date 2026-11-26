"""Private push relay and read-only observer for a restricted Hermes SSH pairing."""

import argparse
import asyncio
from contextlib import asynccontextmanager
import json
import logging
import os
from pathlib import Path
import sys

# Hermes may re-enter a script with runpy and isolated Python, which omits both
# the script directory and PYTHONPATH. Restore this release's trusted paths.
if __name__ == "__main__":
    host = Path(__file__).resolve().parent
    sys.path.insert(0, str(host))
    sys.path.insert(0, str(host.parent / "dependencies"))

from attention_relay import APNs, AttentionState, WORKSPACE_ID, reply_preview, valid


MAX_FRAME = 8192
CHAT_ID = r"[A-Za-z0-9._:-]{1,240}"
LEASE = 8 * 60 * 60
MAX_WATCHES = 32
LOG = logging.getLogger(__name__)


async def exchange(socket, request):
    async with asyncio.timeout(4):
        reader, writer = await asyncio.open_unix_connection(socket, limit=MAX_FRAME)
        try:
            writer.write(json.dumps(request).encode() + b"\n")
            await writer.drain()
            return json.loads(await reader.readline())
        finally:
            writer.close()
            await writer.wait_closed()


async def serve_ssh(socket):
    reader = asyncio.StreamReader(limit=MAX_FRAME)
    loop = asyncio.get_running_loop()
    transport, _ = await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer)
    try:
        request = json.loads(await asyncio.wait_for(reader.readline(), 5))
        if not isinstance(request, dict) or request.get("operation") != "register":
            raise ValueError("Only device registration is allowed over SSH.")
        response = await exchange(socket, request)
    except (OSError, ValueError, TimeoutError):
        response = {"ok": False}
    finally:
        transport.close()
    print(json.dumps(response), flush=True)


def attention(event):
    kind, payload = event.get("type"), event.get("payload", {})
    if kind == "message.complete" and payload.get("status") == "complete":
        admission = payload.get("admission_id") or event.get("admission_id")
        return "reply", admission, "active", reply_preview(payload.get("text"))
    if kind in ("approval.request", "approval.settled", "clarify.request", "clarify.settled"):
        control, stage = kind.split(".")
        return ("approval" if control == "approval" else "input", payload.get("prompt_id"),
                "active" if stage == "request" else "resolved", None)
    return None


class HermesAttention:
    def __init__(self, state, connect, logical_id, workspace_path):
        self.state = state
        self.connect = connect
        self.logical_id = logical_id
        self.workspace_path = workspace_path
        self.state_lock = asyncio.Lock()
        self.watches = {}

    async def handle(self, reader, writer):
        try:
            request = json.loads(await asyncio.wait_for(reader.readline(), 5))
            ok = isinstance(request, dict) and await self.request(request)
            writer.write(json.dumps({"ok": bool(ok)}).encode() + b"\n")
            await writer.drain()
        except (OSError, ValueError, TimeoutError, RuntimeError):
            pass
        finally:
            writer.close()
            await writer.wait_closed()

    async def request(self, request):
        if request == {"operation": "health"}:
            return True
        if request.get("operation") == "register":
            body = request.get("body")
            if not isinstance(body, dict) or not valid(body.get("workspace"), WORKSPACE_ID):
                return False
            async with self.state_lock:
                self.state.register(body)
            return True
        chat = request.get("chat")
        if request.get("operation") != "watch" or not valid(chat, CHAT_ID):
            return False
        async with self.state_lock:
            if not self.state.devices:
                return False
        existing = self.watches.get(chat)
        if existing:
            ready, _ = existing
        else:
            if len(self.watches) >= MAX_WATCHES:
                return False
            ready = asyncio.get_running_loop().create_future()
            task = asyncio.create_task(self.watch(chat, ready))
            self.watches[chat] = (ready, task)
        return await asyncio.shield(ready)

    async def watch(self, chat, ready):
        try:
            async with asyncio.timeout(LEASE):
                async with self.connect() as gateway:
                    session = await asyncio.to_thread(self.logical_id, chat)
                    info = await gateway.rpc("session.info", session_id=session)
                    if info.get("cwd") != self.workspace_path:
                        return
                    snapshot = await gateway.rpc("session.resume", session_id=session)
                    ready.set_result(True)
                    epoch = snapshot.get("replay_epoch")
                    sequence = snapshot.get("last_sequence", 0)
                    while True:
                        # Once attached, the gateway owns the turn and this subscription
                        # stays alive independently of the iPhone's SSH connection.
                        frame = await gateway.events.get()
                        if isinstance(frame, Exception):
                            raise frame
                        event = frame.get("params", {})
                        if event.get("session_id") != session:
                            continue
                        event_epoch, event_sequence = event.get("replay_epoch"), event.get("seq")
                        if isinstance(event_epoch, str) and type(event_sequence) is int:
                            if event_epoch == epoch and event_sequence <= sequence:
                                continue
                            epoch, sequence = event_epoch, event_sequence
                        await self.publish(chat, event, gateway)
        except TimeoutError:
            pass
        except Exception as error:
            # Gateway failures may include provider content, so log only the type.
            LOG.warning("Hermes notification subscription ended (%s)", type(error).__name__)
        finally:
            if not ready.done():
                ready.set_result(False)
            self.watches.pop(chat, None)

    async def publish(self, chat, event, gateway):
        notification = attention(event)
        if not notification:
            return
        reason, event_id, disposition, preview = notification
        if not valid(event_id, r"[A-Za-z0-9._:-]{1,160}"):
            return
        if reason == "reply" and preview is None:
            preview = await self.stored_reply_preview(gateway, event)
            if preview is None:
                return
        async with self.state_lock:
            workspaces = {row["workspace"] for row in self.state.devices.values()}
            for workspace in workspaces:
                self.state.publish({"workspace": workspace, "chat": chat, "reason": reason,
                                    "eventID": event_id, "state": disposition, "preview": preview})

    @staticmethod
    async def stored_reply_preview(gateway, event):
        # A final delivered during streaming can have an empty completion body.
        # The receipt names its exact stored row. Never fall back to an older assistant message.
        receipt = event["payload"].get("persisted_turn") or {}
        row_id = receipt.get("final_assistant_row_id")
        if type(row_id) is not int or row_id <= 0:
            return None
        try:
            async with asyncio.timeout(3):
                page = await gateway.rpc("session.transcript", session_id=event["session_id"],
                                         order="latest", limit=20, inline_images=False)
        except Exception as error:
            LOG.warning("Hermes notification reply lookup failed (%s)", type(error).__name__)
            return None
        for row in page.get("rows", []):
            if row.get("row_id") == row_id and row.get("role") == "assistant":
                return reply_preview(row.get("text"))
        return None

    async def flush(self):
        while True:
            await asyncio.sleep(0.5)
            async with self.state_lock:
                if self.state.pending:
                    await asyncio.to_thread(self.state.flush)


async def run(args):
    sys.path.insert(0, str(args.hermes_source))
    sys._hermes_pin_default_home = True
    import hermes_bootstrap  # noqa: F401 - configures Hermes's installed dependencies
    from acp_adapter.catalog import logical_session_id
    from hermes_cli.gateway_client import connect_gateway
    from hermes_cli.gateway_runtime import discover_gateway_endpoint

    @asynccontextmanager
    async def connect():
        discovery = await asyncio.to_thread(discover_gateway_endpoint, args.profile)
        if discovery.state != "ready" or discovery.endpoint is None:
            raise RuntimeError("The Hermes gateway is unavailable.")
        async with connect_gateway(endpoint=discovery.endpoint) as gateway:
            yield gateway

    sender = APNs(team=args.team, key_id=args.key_id, topic="app.riptide.client", key_file=args.key)
    state = AttentionState(send=sender.send, device_file=args.state / "devices.json")
    relay = HermesAttention(state, connect, lambda chat: logical_session_id(args.profile, chat), args.workspace)
    socket = args.state / "attention.sock"
    socket.unlink(missing_ok=True)
    server = await asyncio.start_unix_server(relay.handle, path=socket, limit=MAX_FRAME)
    async with server, asyncio.TaskGroup() as tasks:
        tasks.create_task(relay.flush())
        tasks.create_task(server.serve_forever())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--profile", required=True, type=Path)
    parser.add_argument("--hermes-source", required=True, type=Path)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--key", required=True, type=Path)
    parser.add_argument("--team", required=True)
    parser.add_argument("--key-id", required=True)
    args = parser.parse_args()
    os.umask(0o077)
    if args.state.stat().st_mode & 0o077:
        parser.error("Use a private relay state directory.")
    os.environ["HERMES_HOME"] = str(args.profile)
    logging.basicConfig(level=logging.INFO)
    logging.getLogger("httpx").setLevel(logging.WARNING)  # The request URL contains the device token.
    asyncio.run(run(args))


if __name__ == "__main__":
    main()
