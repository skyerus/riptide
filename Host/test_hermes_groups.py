import asyncio
import json
import unittest
from unittest.mock import AsyncMock, patch

from hermes_groups import admitted, relay


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
