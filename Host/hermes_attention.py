"""Private push relay and read-only observer for a restricted Hermes SSH pairing."""

import argparse
import asyncio
from contextlib import asynccontextmanager
from dataclasses import replace
import hashlib
import json
import logging
import os
from pathlib import Path
import re
import shlex
import sys
import uuid

# Hermes may re-enter a script with runpy and isolated Python, which omits both
# the script directory and PYTHONPATH. Restore this release's trusted paths.
if __name__ == "__main__":
    host = Path(__file__).resolve().parent
    sys.path.insert(0, str(host))
    sys.path.insert(0, str(host.parent / "dependencies"))

from attention_relay import APNs, AttentionState, WORKSPACE_ID, reply_preview, valid
from hermes_chrome_profile import owned_directory
from ssh_pairing_files import Edit, PROFILE, key_identity, lock_keys, read_owned


MAX_FRAME = 8192
MAX_REPLY_FRAME = 2 * 1024 * 1024
CHAT_ID = r"[A-Za-z0-9._:-]{1,240}"
EVENT_ID = r"[A-Za-z0-9._:-]{1,160}"
REPLY_LIFETIME = 15 * 60
LEASE = 8 * 60 * 60
MAX_WATCHES = 32
LOG = logging.getLogger(__name__)


async def exchange(socket, request, *, reply=False):
    async with asyncio.timeout(4):
        reader, writer = await asyncio.open_unix_connection(socket, limit=MAX_REPLY_FRAME if reply else MAX_FRAME)
        try:
            writer.write(json.dumps(request).encode() + b"\n")
            await writer.drain()
            return json.loads(await reader.readline())
        finally:
            writer.close()
            await writer.wait_closed()


def configure_reply_key(path, socket, scope, device, key):
    marker = "riptide-notification-" + hashlib.sha256(json.dumps([scope, device]).encode()).hexdigest()
    argv = [sys.executable, str(Path(__file__).with_name("ssh_acp.py").resolve()),
            "--attention-socket", str(socket), "--notification-device", device,
            "--workspace", scope["workspace"] if scope else "/"]
    if scope:
        argv.extend(["--attention-profile", scope["profile"]])
    with lock_keys(path):
        original, mode = read_owned(path)
        if original is None:
            raise ValueError("Missing restricted SSH key file.")
        lines = [line for line in original.decode().splitlines(keepends=True)
                 if (not line.startswith('restrict,command="') or line.rstrip().split()[-1] != marker)]
        source = "".join(lines)
        if key is not None:
            if not valid(key, r"ssh-ed25519 [A-Za-z0-9+/=]{50,100}"):
                raise ValueError("Invalid reply key.")
            key = " ".join(key_identity(key))
            if re.search(rf"(?:^|\s){re.escape(key)}(?=\s|$)", source, re.MULTILINE):
                raise ValueError("Reply key is already assigned.")
            command = shlex.join(argv).replace('"', r'\"')
            if any(char in command for char in "\r\n"):
                raise ValueError("Invalid reply command.")
            source += ("" if not source or source.endswith("\n") else "\n")
            source += f'restrict,command="{command}" {key} {marker}\n'
        Edit(path, original, source.encode(), mode).apply()


async def serve_ssh(socket, scope=None, *, device=None):
    reader = asyncio.StreamReader(limit=MAX_FRAME)
    loop = asyncio.get_running_loop()
    transport, _ = await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer)
    try:
        request = json.loads(await asyncio.wait_for(reader.readline(), 5))
        if device is not None:
            if not isinstance(request, dict) or set(request) != {"chat", "eventID"}:
                raise ValueError("Only alert reply lookup is allowed with this key.")
            request.update(operation="reply", device=device)
        else:
            if (not isinstance(request, dict) or set(request) != {"operation", "body"}
                    or request["operation"] != "register" or not isinstance(request["body"], dict)):
                raise ValueError("Only device registration is allowed over SSH.")
            body = request["body"]
            key = body.pop("replyPreloadKey", None)
            preload = body.pop("supportsReplyPreload", None) is True
            body.pop("replyPreload", None)
            policy = body.get("policy", {})
            if preload:
                if str(uuid.UUID(body["id"])) != body.get("workspace", "").lower():
                    raise ValueError("Registration must match its device ID.")
                enabled = body.get("token") is not None and policy.get("replies") is True and policy.get("delivery") != "off"
                try:
                    await asyncio.to_thread(configure_reply_key, Path.home() / ".ssh" / "authorized_keys",
                                            socket, scope, body["id"], key if enabled else None)
                    body["replyPreload"] = enabled and key is not None
                except (OSError, ValueError):
                    LOG.warning("Could not configure the notification reply key")
        if scope is not None:
            request["scope"] = scope
        response = await exchange(socket, request, reply=device is not None)
    except (OSError, ValueError, TypeError, AttributeError, KeyError, TimeoutError):
        response = {"ok": False}
    finally:
        transport.close()
    print(json.dumps(response, ensure_ascii=False), flush=True)


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
        if request.get("operation") == "reply":
            return await self.read_reply(request)
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
                    snapshot = await gateway.rpc("session.resume", session_id=session, omit_messages=True)
                    session = snapshot.get("session_id") or session
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
        if not valid(event_id, EVENT_ID):
            return
        row = (event["payload"].get("persisted_turn") or {}).get("final_assistant_row_id") if reason == "reply" else None
        if reason == "reply" and preview is None:
            preview = reply_preview(await self.stored_reply(gateway, event["session_id"], row))
            if preview is None:
                return
        async with self.state_lock:
            workspaces = {row["workspace"] for row in self.state.devices.values()}
            for workspace in workspaces:
                self.state.publish({"workspace": workspace, "chat": chat, "reason": reason,
                                    "eventID": event_id, "state": disposition, "preview": preview, "replyRow": row})

    async def read_reply(self, request):
        device, chat, event_id = (request.get(key) for key in ("device", "chat", "eventID"))
        if not valid(chat, CHAT_ID) or not valid(event_id, EVENT_ID):
            return False
        async with self.state_lock:
            registration = self.state.devices.get(device)
            if not registration or not registration["replyPreload"] or not registration["policy"]["replies"]:
                return False
            item = self.state.inbox.get((registration["workspace"], chat, "reply"))
            if not item or item[0].event_id != event_id or not 0 <= self.state.clock() - item[1] <= REPLY_LIFETIME:
                return False
            row = item[0].reply_row
        if row is None:
            return False
        async with self.connect() as gateway:
            session = await asyncio.to_thread(self.logical_id, chat)
            info = await gateway.rpc("session.info", session_id=session)
            if info.get("cwd") != self.workspace_path:
                return False
            text = await self.stored_reply(gateway, session, row)
        async with self.state_lock:
            if self.state.devices.get(device) is not registration:
                return False
        return {"text": text} if reply_preview(text) else False

    @staticmethod
    async def stored_reply(gateway, session, row_id):
        # A final delivered during streaming can have an empty completion body.
        # The receipt names its exact stored row. Never fall back to an older assistant message.
        if type(row_id) is not int or row_id <= 0:
            return None
        try:
            async with asyncio.timeout(3):
                page = await gateway.rpc("session.transcript", session_id=session,
                                         order="latest", limit=20, inline_images=False)
        except Exception as error:
            LOG.warning("Hermes notification reply lookup failed (%s)", type(error).__name__)
            return None
        for row in page.get("rows", []):
            if row.get("row_id") == row_id and row.get("role") == "assistant":
                return row.get("text")
        return None

    async def flush(self):
        async with self.state_lock:
            if self.state.pending:
                await asyncio.to_thread(self.state.flush)


class HermesAttentionRouter:
    def __init__(self, state_dir, default_home, default_workspace, connect, logical_id, send):
        self.state_dir = state_dir
        self.default_home = default_home
        self.connect = connect
        self.logical_id = logical_id
        self.send = send
        self.default_scope = ("default", default_workspace)
        self.relays = {self.default_scope: self.make_relay(default_home, default_workspace, state_dir)}

    def make_relay(self, home, workspace, state_dir):
        state = AttentionState(send=self.send, device_file=state_dir / "devices.json")
        return HermesAttention(state, lambda: self.connect(home),
                               lambda chat: self.logical_id(home, chat), workspace)

    def scope(self, value):
        if value is None:
            return self.default_scope, self.default_home
        if not isinstance(value, dict) or set(value) != {"profile", "workspace"}:
            raise ValueError("Invalid Hermes notification scope.")
        profile, workspace = value["profile"], value["workspace"]
        if (not isinstance(profile, str) or not PROFILE.fullmatch(profile)
                or not isinstance(workspace, str) or not Path(workspace).is_absolute()
                or not Path(workspace).is_dir()):
            raise ValueError("Invalid Hermes notification scope.")
        home = self.default_home
        if profile != "default":
            profiles = home / "profiles"
            owned_directory(profiles)
            home = profiles / profile
            owned_directory(home)
        return (profile, workspace), home

    async def request(self, request):
        operation = request.get("operation")
        if operation not in ("health", "register", "watch", "reply"):
            return False
        scope, home = self.scope(request.get("scope"))
        if operation == "health":
            return True
        relay = self.relays.get(scope)
        if relay is None:
            name = hashlib.sha256(json.dumps(scope).encode()).hexdigest()
            state_dir = self.state_dir / name
            state_dir.mkdir(exist_ok=True, mode=0o700)
            owned_directory(state_dir)
            relay = self.relays[scope] = self.make_relay(home, scope[1], state_dir)
        return await relay.request({key: value for key, value in request.items() if key != "scope"})

    async def handle(self, reader, writer):
        ok = False
        try:
            request = json.loads(await asyncio.wait_for(reader.readline(), 5))
            ok = isinstance(request, dict) and await self.request(request)
        except (OSError, ValueError, TypeError, TimeoutError, RuntimeError):
            pass
        try:
            response = {"ok": bool(ok)}
            if isinstance(ok, dict):
                response.update(ok)
            data = json.dumps(response, ensure_ascii=False).encode()
            writer.write((data if len(data) < MAX_REPLY_FRAME else b'{"ok":false}') + b"\n")
            await writer.drain()
        except OSError:
            pass
        finally:
            writer.close()
            await writer.wait_closed()

    async def flush(self):
        while True:
            await asyncio.sleep(0.5)
            # The APNs client is shared, so send through one scope at a time.
            for relay in list(self.relays.values()):
                await relay.flush()


async def run(args):
    sys.path.insert(0, str(args.hermes_source))
    sys._hermes_pin_default_home = True
    import hermes_bootstrap  # noqa: F401 - configures Hermes's installed dependencies
    from acp_adapter.catalog import logical_session_id
    from hermes_cli.gateway_client import connect_gateway
    from hermes_cli.gateway_runtime import discover_gateway_endpoint

    @asynccontextmanager
    async def connect(home):
        discovery = await asyncio.to_thread(discover_gateway_endpoint, home)
        if discovery.state != "ready" or discovery.endpoint is None:
            raise RuntimeError("The Hermes gateway is unavailable.")
        endpoint = discovery.endpoint
        if endpoint.control_home is None:
            endpoint = replace(endpoint, control_home=str(home))
        async with connect_gateway(endpoint=endpoint) as gateway:
            yield gateway

    sender = APNs(team=args.team, key_id=args.key_id, topic="app.riptide.client", key_file=args.key)
    relay = HermesAttentionRouter(args.state, args.profile, args.workspace, connect, logical_session_id, sender.send)
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
