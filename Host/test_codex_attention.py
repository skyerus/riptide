import unittest

from codex_attention import AppServer, enqueue, safe_origin, transitions


class CodexAttentionTests(unittest.IsolatedAsyncioTestCase):
    def test_only_real_attention_transitions_are_published(self):
        prior = {"one": ("approval", 1), "two": ("active", 3), "three": ("active", 3)}
        current = {"one": ("active", 4), "two": ("idle", 4), "three": ("notLoaded", 4),
                   "four": ("idle", 5), "five": ("input", 6)}
        self.assertEqual(list(transitions(prior, current)), [
            ("one", "approval", "resolved", 4), ("two", "reply", "active", 4),
            ("five", "input", "active", 6),
        ])

    def test_credentials_never_go_to_plaintext_remote_or_urls_with_auth(self):
        self.assertEqual(safe_origin("ws://127.0.0.1:5000", socket=True), "ws://127.0.0.1:5000")
        for origin in ("http://remote.example", "https://user:pass@remote.example", "https://local.example/?token=x"):
            with self.assertRaises(ValueError):
                safe_origin(origin)

    def test_offline_outbox_sends_only_the_resolution_for_a_request_already_answered(self):
        pending = {}
        event = {"workspace": "agent", "chat": "main", "reason": "approval", "eventID": "receipt"}
        enqueue(pending, {**event, "state": "active"})
        enqueue(pending, {**event, "state": "resolved"})
        self.assertEqual(list(pending.values()), [{**event, "state": "resolved"}])

    async def test_watch_checks_account_before_listing_or_sending_any_events(self):
        class FakeAppServer(AppServer):
            async def call(self, method, params):
                self.calls.append(method)
                if method == "account/read":
                    return {"account": {"type": "chatgpt"}, "workspaceRouting": {"chatgptAccountId": "different"}}
                self.fail_unexpected = True

        server = FakeAppServer(None)
        server.calls = []
        with self.assertRaises(RuntimeError):
            await server.list_status("/workspace", "expected")
        self.assertEqual(server.calls, ["account/read"])
