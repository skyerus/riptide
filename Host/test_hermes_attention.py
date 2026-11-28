import asyncio
from contextlib import asynccontextmanager
import json
import os
from pathlib import Path
import runpy
import shlex
import subprocess
import sys
import tempfile
import unittest

from attention_relay import AttentionState
from hermes_attention import HermesAttention, HermesAttentionRouter, REPLY_LIFETIME, attention, configure_reply_key


class Gateway:
    def __init__(self, cwd="/paired"):
        self.events = asyncio.Queue()
        self.calls = []
        self.cwd = cwd

    async def rpc(self, method, *, session_id, **params):
        self.calls.append((method, session_id, params))
        if method == "session.transcript":
            return {"rows": [
                {"row_id": 20, "role": "assistant", "text": "An older reply."},
                {"row_id": 23, "role": "assistant", "text": "\nThe streamed reply.\nSecond line."},
                {"row_id": 25, "role": "user", "text": "A later prompt."},
            ]}
        return {"cwd": self.cwd, "replay_epoch": "current", "last_sequence": 4}

    async def publish(self, kind, payload, *, seq=5, session="canonical"):
        await self.events.put({"params": {"type": kind, "payload": payload, "session_id": session,
                                         "replay_epoch": "current", "seq": seq}})
        await asyncio.sleep(0)


class HermesAttentionTests(unittest.IsolatedAsyncioTestCase):
    def test_reply_key_replaces_only_its_restricted_route(self):
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        keys = root / "authorized_keys"
        retained = b"# keep other authorized keys\n"
        keys.write_bytes(retained)
        identity = root / "key"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(identity)], check=True)
        key = " ".join((root / "key.pub").read_text().split()[:2])
        scope = {"profile": "accountant", "workspace": str(root)}
        device = "00000000-0000-0000-0000-000000000005"
        for _ in range(2):
            configure_reply_key(keys, root / "attention.sock", scope, device, key)
        self.assertEqual(keys.read_bytes().count(key.encode()), 1)
        self.assertIn(b'restrict,command="', keys.read_bytes())
        self.assertIn(b"--notification-device", keys.read_bytes())
        self.assertNotIn(b"--pairing-config", keys.read_bytes())
        configure_reply_key(keys, root / "attention.sock", scope, device, None)
        self.assertEqual(keys.read_bytes(), retained)

    async def test_only_the_registered_reply_device_can_fetch_the_exact_full_message(self):
        gateway = Gateway()
        full_text = "The release is ready.\n" + "Details below. " * 900
        rpc = gateway.rpc

        async def long_reply(method, **params):
            result = await rpc(method, **params)
            if method == "session.transcript":
                result["rows"][1]["text"] = full_text
            return result

        gateway.rpc = long_reply
        now = 1234

        @asynccontextmanager
        async def connect():
            yield gateway

        state = AttentionState(send=lambda *_: "sent", clock=lambda: now)
        relay = HermesAttention(state, connect, lambda _: "canonical", "/paired")
        device = "00000000-0000-0000-0000-000000000005"
        registration = {"id": device, "workspace": device, "environment": "production", "token": "a" * 64,
                        "policy": {"delivery": "always", "approvals": True, "replies": True}, "replyPreload": True}
        state.register(registration)
        await relay.publish("editor", {"session_id": "canonical", "type": "message.complete", "payload": {
            "status": "complete", "admission_id": "notice", "persisted_turn": {"final_assistant_row_id": 23},
        }}, gateway)
        request = {"operation": "reply", "device": device, "chat": "editor", "eventID": "notice"}
        self.assertEqual(await relay.request(request), {"text": full_text})
        self.assertFalse(await relay.request({**request, "eventID": "older"}))
        self.assertFalse(await relay.request({**request, "chat": "different"}))
        self.assertFalse(await relay.request({**request, "device": "00000000-0000-0000-0000-000000000006"}))
        gateway.cwd = "/moved"
        self.assertFalse(await relay.request(request))
        gateway.cwd = "/paired"
        now += REPLY_LIFETIME + 1
        self.assertFalse(await relay.request(request))
        now -= REPLY_LIFETIME + 1
        state.register({**registration, "token": None})
        self.assertFalse(await relay.request(request))

    async def test_watch_survives_its_caller_and_routes_only_current_events(self):
        gateway = Gateway()

        @asynccontextmanager
        async def connect():
            yield gateway

        sent = []
        state = AttentionState(send=lambda device, event: sent.append((device["workspace"], event)) or "sent")
        relay = HermesAttention(state, connect, lambda _: "canonical", "/paired")
        self.assertFalse(await relay.request({"operation": "watch", "chat": "editor"}))
        policy = {"delivery": "always", "approvals": True, "replies": True}
        self.assertTrue(await relay.request({"operation": "register", "body": {
            "id": "00000000-0000-0000-0000-000000000001", "workspace": "phone-workspace", "token": "a" * 64,
            "environment": "production", "policy": policy,
        }}))
        watch = {"operation": "watch", "chat": "editor"}
        self.assertTrue(await relay.request(watch))
        self.assertTrue(await relay.request(watch))
        self.assertEqual(gateway.calls, [("session.info", "canonical", {}),
                                         ("session.resume", "canonical", {"omit_messages": True})])
        await gateway.publish("message.complete", {"status": "complete", "admission_id": "old"}, seq=4)
        await gateway.publish("message.complete", {"status": "complete", "admission_id": "other"}, session="other")
        await gateway.publish("approval.request", {"prompt_id": "request-1", "command": "private"}, seq=6)
        await gateway.publish("approval.settled", {"prompt_id": "request-1"}, seq=7)
        await gateway.publish("message.complete", {"status": "error", "admission_id": "failed"}, seq=8)
        await gateway.publish("message.complete", {
            "status": "complete", "admission_id": "reply-1", "text": "\nThe report is ready.\nThe rest of the reply.",
        }, seq=9)
        await gateway.publish("clarify.request", {"prompt_id": "input-2", "question": "private"}, seq=10)
        state.flush()
        await gateway.publish("message.complete", {
            "status": "complete", "admission_id": "blank", "text": " \n\t",
        }, seq=11)
        await gateway.publish("message.complete", {
            "status": "complete", "admission_id": "replayed", "text": "A replayed reply",
        }, seq=9)
        await gateway.publish("message.complete", {
            "status": "complete", "admission_id": "missing-row", "persisted_turn": {"final_assistant_row_id": 22},
        }, seq=12)
        state.flush()
        await gateway.publish("message.complete", {
            "status": "complete", "admission_id": "streamed", "persisted_turn": {"final_assistant_row_id": 23},
        }, seq=13)
        state.publish({"workspace": "unpaired", "chat": "editor", "reason": "input", "eventID": "other"})
        state.flush()
        self.assertEqual(gateway.calls[2:], [
            ("session.transcript", "canonical", {"order": "latest", "limit": 20, "inline_images": False}),
        ] * 2)
        self.assertEqual([(workspace, item.chat, item.reason, item.event_id) for workspace, item in sent],
                         [("phone-workspace", "editor", "reply", "reply-1"),
                          ("phone-workspace", "editor", "input", "input-2"),
                          ("phone-workspace", "editor", "reply", "streamed")])
        self.assertEqual([item.preview for _, item in sent], ["The report is ready.", None, "The streamed reply."])
        self.assertTrue(all("preview" not in row for row in state.entries()))
        _, task = relay.watches["editor"]
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)

    async def test_other_directory_never_subscribes(self):
        gateway = Gateway()

        @asynccontextmanager
        async def connect():
            yield gateway

        state = AttentionState(send=lambda *_: "sent")
        state.devices["test"] = {"workspace": "test"}
        relay = HermesAttention(state, connect, lambda chat: chat, "/different")
        self.assertFalse(await relay.request({"operation": "watch", "chat": "editor"}))
        self.assertEqual(gateway.calls, [("session.info", "editor", {})])

    def test_input_notifications_match_the_same_pending_request(self):
        payload = {"prompt_id": "input-1"}
        self.assertEqual(attention({"type": "clarify.request", "payload": payload}), ("input", "input-1", "active", None))
        self.assertEqual(attention({"type": "clarify.settled", "payload": payload}), ("input", "input-1", "resolved", None))

    async def test_router_isolates_registered_devices_and_cursors_by_profile_and_workspace(self):
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        state = root / "state"
        state.mkdir()
        first_home, second_home = (root / "profiles" / name for name in ("first", "second"))
        first_home.mkdir(parents=True)
        second_home.mkdir()
        shared_workspace = str(root)
        other_workspace = str(state)
        gateways = {home: Gateway(shared_workspace) for home in (root, first_home, second_home)}

        @asynccontextmanager
        async def connect(home):
            yield gateways[home]

        sent = []
        def send(device, event):
            sent.append((device["workspace"], event.preview))
            return "sent"

        def scoped(profile, workspace, **request):
            return {**request, "scope": {"profile": profile, "workspace": workspace}}

        def registration(index):
            return {"operation": "register", "body": {
                "id": f"00000000-0000-0000-0000-{index:012}",
                "workspace": f"phone-{index}", "token": "a" * 64, "environment": "production",
                "policy": {"delivery": "always", "approvals": True, "replies": True},
            }}

        def make_router():
            return HermesAttentionRouter(state, root, shared_workspace, connect, lambda home, chat: chat, send)

        router = make_router()
        self.assertTrue(await router.request(registration(1)))
        self.assertTrue(await router.request(scoped("first", shared_workspace, **registration(2))))
        self.assertTrue(await router.request(scoped("second", shared_workspace, **registration(3))))
        self.assertTrue(await router.request(scoped("second", other_workspace, **registration(4))))
        with self.assertRaises(ValueError):
            await router.request(scoped("../first", shared_workspace, operation="health"))
        self.assertTrue((state / "devices.json").exists())

        router = make_router()  # All registrations survive a relay restart.
        watch = {"operation": "watch", "chat": "canonical"}
        self.assertTrue(await router.request(watch))
        self.assertTrue(await router.request(scoped("first", shared_workspace, **watch)))
        self.assertTrue(await router.request(scoped("second", shared_workspace, **watch)))
        self.assertFalse(await router.request(scoped("second", other_workspace, **watch)))
        for home, gateway in gateways.items():
            await gateway.publish("message.complete", {"status": "complete", "admission_id": "same-id",
                                                       "text": home.name})
        for relay in router.relays.values():
            await relay.flush()
        self.assertEqual(sent, [("phone-1", root.name), ("phone-2", "first"), ("phone-3", "second")])
        tasks = [task for relay in router.relays.values() for _, task in relay.watches.values()]
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)

    async def test_ssh_registration_and_new_turn_use_the_same_host_selected_scope(self):
        root = Path(self.enterContext(tempfile.TemporaryDirectory(dir="/tmp")))
        socket = root / "relay.sock"
        scope = {"profile": "fixture", "workspace": str(root)}
        requests = []

        async def record(reader, writer):
            requests.append(json.loads(await reader.readline()))
            writer.write(b'{"ok":true}\n')
            await writer.drain()
            writer.close()
            await writer.wait_closed()

        agent = ("import json, sys\nfor line in sys.stdin:\n"
                 "    print(json.dumps({'id': json.loads(line)['id'], 'result': {}}), flush=True)")
        wrapper = Path(__file__).with_name("ssh_acp.py")
        keys = root / ".ssh" / "authorized_keys"
        keys.parent.mkdir()
        keys.touch()
        identity = root / "reply-key"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(identity)], check=True)
        public_key = " ".join(identity.with_suffix(".pub").read_text().split()[:2])
        server = await asyncio.start_unix_server(record, path=socket)
        async with server:
            async def launch(route):
                return await asyncio.create_subprocess_exec(
                    sys.executable, str(wrapper), "--workspace", str(root), "--attention-socket", str(socket),
                    "--attention-profile", "fixture", "--", sys.executable, "-c", agent,
                    env={**os.environ, "SSH_ORIGINAL_COMMAND": route, "HOME": str(root)},
                    stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                )

            registration = {"operation": "register", "body": {}}
            ssh = await launch("riptide-attention")
            response, _ = await asyncio.wait_for(ssh.communicate(json.dumps(registration).encode() + b"\n"), 5)
            self.assertEqual(json.loads(response), {"ok": True})
            ssh = await launch("riptide-attention")
            forged = {**registration, "scope": {**scope, "profile": "another"}}
            response, _ = await asyncio.wait_for(ssh.communicate(json.dumps(forged).encode() + b"\n"), 5)
            self.assertEqual(json.loads(response), {"ok": False})

            device = "00000000-0000-0000-0000-000000000005"
            body = {"id": device, "workspace": device, "token": "a" * 64, "environment": "development",
                    "policy": {"delivery": "always", "replies": True, "approvals": True}}
            preload = {"operation": "register", "body": {**body, "supportsReplyPreload": True,
                                                         "replyPreloadKey": public_key}}
            ssh = await launch("riptide-attention")
            response, _ = await asyncio.wait_for(ssh.communicate(json.dumps(preload).encode() + b"\n"), 5)
            self.assertEqual(json.loads(response), {"ok": True})
            self.assertIn(public_key, keys.read_text())

            ssh = await launch("riptide-acp")
            try:
                for index, (method, params) in enumerate((
                    ("session/load", {"sessionId": "test", "cwd": str(root), "mcpServers": []}),
                    ("session/prompt", {"sessionId": "test", "prompt": [{"type": "text", "text": "Fixture"}]}),
                )):
                    request = {"jsonrpc": "2.0", "id": index, "method": method, "params": params}
                    ssh.stdin.write(json.dumps(request).encode() + b"\n")
                    await ssh.stdin.drain()
                    result = json.loads(await asyncio.wait_for(ssh.stdout.readline(), 5))
                    self.assertEqual(result["id"], index)
            finally:
                ssh.stdin.close()
                await asyncio.wait_for(ssh.wait(), 5)
        self.assertEqual(requests, [{**registration, "scope": scope},
                                    {"operation": "register", "scope": scope, "body": {**body, "replyPreload": True}},
                                    {"operation": "watch", "scope": scope, "chat": "test"}])

    def test_rollout_rewrites_only_restricted_hermes_keys_and_can_be_repeated(self):
        deployment = Path(__file__).parent / "deploy" / "enable-hermes-attention.py"
        key_edits = runpy.run_path(str(deployment))["key_edits"]
        hermes = Path("/opt/bin/hermes")
        wrapper = Path("/opt/release/Host/ssh_acp.py")
        socket = Path("/run/push.sock")
        prefix = ["/usr/bin/python3", "/older/Host/ssh_acp.py", "--workspace", "/work space"]

        def key(index, command):
            return f'restrict,command="{shlex.join(command)}" ssh-ed25519 AAA{index} agent-{index}\n'

        default = key(1, [*prefix, "--attention-socket", str(socket), "--", str(hermes), "acp"])
        named = key(2, [*prefix, "--", str(hermes), "--profile", "accountant", "acp"])
        unrelated = key(3, [*prefix, "--", "/opt/bin/other-acp"])
        updated, count, scopes = key_edits(default + named + unrelated, hermes, wrapper, socket)
        self.assertEqual(count, 2)
        self.assertEqual(scopes, {("default", "/work space"), ("accountant", "/work space")})
        self.assertEqual(updated.count(str(wrapper)), 2)
        self.assertIn("--attention-profile accountant --", updated)
        self.assertTrue(updated.endswith(unrelated))
        self.assertEqual(key_edits(updated, hermes, wrapper, socket)[0], updated)
