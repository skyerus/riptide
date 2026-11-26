import asyncio
from contextlib import asynccontextmanager
import unittest

from attention_relay import AttentionState
from hermes_attention import HermesAttention, attention


class Gateway:
    def __init__(self):
        self.events = asyncio.Queue()
        self.calls = []

    async def rpc(self, method, *, session_id, **params):
        self.calls.append((method, session_id, params))
        if method == "session.transcript":
            return {"rows": [
                {"row_id": 20, "role": "assistant", "text": "An older reply."},
                {"row_id": 23, "role": "assistant", "text": "\nThe streamed reply.\nSecond line."},
                {"row_id": 25, "role": "user", "text": "A later prompt."},
            ]}
        return {"cwd": "/paired", "replay_epoch": "current", "last_sequence": 4}

    async def publish(self, kind, payload, *, seq=5, session="canonical"):
        await self.events.put({"params": {"type": kind, "payload": payload, "session_id": session,
                                         "replay_epoch": "current", "seq": seq}})
        await asyncio.sleep(0)


class HermesAttentionTests(unittest.IsolatedAsyncioTestCase):
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
        self.assertEqual(gateway.calls, [("session.info", "canonical", {}), ("session.resume", "canonical", {})])
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
