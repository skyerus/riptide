import asyncio
import base64
import json
from pathlib import Path
import shutil
import unittest
from unittest.mock import AsyncMock, patch

from hermes_groups import admitted, relay
from ssh_acp import STAGE_ATTACHMENTS


def request(method, **params):
    return {"jsonrpc": "2.0", "id": "client", "method": method, "params": params}


class HermesGroupsTests(unittest.IsolatedAsyncioTestCase):
    def test_pairing_cannot_route_to_another_profile_or_gateway(self):
        members = [{"member_id": profile, "profile": profile, "handle": profile}
                   for profile in ("writer", "reviewer")]
        self.assertTrue(admitted(request("groups.create", room_id="room", name="Review", members=members)))
        members[1]["target"] = {"kind": "peer", "peer_id": "other"}
        self.assertFalse(admitted(request("groups.create", room_id="room", name="Review", members=members)))
        self.assertFalse(admitted(request("groups.capabilities", profile="other")))
        self.assertFalse(admitted(request("groups.peer.register", room_id="room")))
        self.assertFalse(admitted(request("profiles.list", include_sessions=True)))

    async def test_advertises_and_stages_files_without_forwarding_them_to_the_gateway(self):
        reader = asyncio.StreamReader()
        data = b"%PDF-group fixture"
        for packet in (
            request("groups.capabilities"),
            request(STAGE_ATTACHMENTS, files=[{"name": "report.pdf", "dataBase64": base64.b64encode(data).decode()}]),
        ):
            reader.feed_data(json.dumps(packet).encode() + b"\n")
        reader.feed_eof()
        gateway = AsyncMock()
        gateway.recv.return_value = json.dumps({"id": "client", "result": {"methods": ["groups.send"]}})
        with patch("hermes_groups.write") as write:
            await relay(reader, gateway)
        self.assertIn(STAGE_ATTACHMENTS, write.call_args_list[0].args[0]["result"]["methods"])
        file = Path(write.call_args_list[1].args[0]["result"]["paths"][0])
        self.addCleanup(shutil.rmtree, file.parent)
        self.assertEqual(file.read_bytes(), data)
        self.assertEqual(gateway.send.await_count, 1)

    async def test_forwards_only_admitted_requests_and_returns_matching_reply(self):
        reader = asyncio.StreamReader()
        chat = request("groups.send", room_id="room", event_id="message", payload={
            "text": "@reviewer Compare the two examples. \x60date\x60", "thread_id": "thread",
        })
        refused = {**request("session.run"), "id": "outside-scope"}
        for packet in (refused, chat):
            reader.feed_data(json.dumps(packet).encode() + b"\n")
        reader.feed_eof()
        receipt = {"jsonrpc": "2.0", "id": "client", "result": {"client_event_id": "message", "accepted": True}}
        gateway = AsyncMock()
        gateway.recv.side_effect = [json.dumps({"method": "groups.changed"}), json.dumps(receipt)]
        with patch("hermes_groups.write") as write:
            await relay(reader, gateway)
        self.assertEqual(write.call_args_list[0].args[0]["id"], "outside-scope")
        self.assertEqual(write.call_args_list[1].args[0], receipt)
        self.assertEqual(gateway.send.await_count, 1)
        self.assertEqual(json.loads(gateway.send.call_args.args[0]), chat)
