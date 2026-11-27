import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from hermes_ssh_talk import TalkCall, TalkError


class HermesSSHTalkTests(unittest.TestCase):
    def setUp(self):
        directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.config = directory / "talk.json"
        self.config.write_text(json.dumps({"port": 9119, "profile": "sandbox", "dashboardToken": "d" * 40}))
        self.config.chmod(0o600)
        self.call = TalkCall(self.config)
        self.selection = {"peer_id": "local", "profile": "sandbox", "session_id": "test-chat"}
        self.attachment = {"tab_id": self.call.tab, "target_id": "test-target"}
        self.context = {"connection_id": "test-connection", "generation": 3}
        self.ready = {"ok": True, "configured": True, "voiceMode": "live", "liveAuth": "subscription",
                      "source": "codex-oauth", "model": "gpt-live-1-codex", "taskContinuity": {"supported": True}}
        self.catalog = {"ok": True, "targets": [{**self.selection, "target_id": "test-target"}]}
        self.bound = {"ok": True, "input_mode": "typed", "task": {
            **self.attachment, **self.selection, **self.context,
        }, "selection": {"state": "activated", "target_id": "test-target"}}

    def test_requires_a_private_host_config(self):
        self.config.chmod(0o640)
        with self.assertRaisesRegex(TalkError, "^disabled$"):
            TalkCall(self.config)

    def test_matches_the_exact_profile_and_returns_only_call_data(self):
        with patch.object(self.call, "send", side_effect=[
            self.ready, self.catalog, self.bound, self.ready,
            {"ok": True, "binding_id": "test-binding", "sdp": "v=0 answer", "internal": "keep private"},
            {"ok": True, "cursor": 1, "events": [{"sequence": 1, "type": "result", "internal": "keep private"}]},
            {"ok": True}, {"ok": True},
        ]) as send:
            self.assertEqual(self.call.start("test-chat", "v=0 offer"), {"ok": True, "sdp": "v=0 answer"})
            self.assertEqual(self.call.events(0), {"ok": True, "cursor": 1, "events": [{"sequence": 1, "type": "result"}]})
            with self.assertRaisesRegex(TalkError, "^invalidRequest$"):
                self.call.start("another-chat", "v=0 offer")
            self.call.close()

        bound = {**self.context, "binding_id": "test-binding"}
        self.assertEqual([call.args for call in send.call_args_list], [
            ("/status",), ("/targets", {**self.selection, "tab_id": self.call.tab}),
            ("/native/attach", {**self.attachment, "input_mode": "typed", "surface": "dashboard"}),
            ("/status",), ("/live/session", {**self.context, "sdp": "v=0 offer"}),
            ("/live/events", {**bound, "after": 0}), ("/live/close", bound), ("/close", self.context),
        ])

    def test_wrong_profile_is_never_attached(self):
        other_profile = {"ok": True, "targets": [{**self.selection, "profile": "other", "target_id": "test-target"}]}
        with patch.object(self.call, "send", side_effect=[self.ready, other_profile]) as send:
            with self.assertRaisesRegex(TalkError, "^wrongChat$"):
                self.call.start("test-chat", "v=0 offer")
            self.call.close()
        self.assertEqual([call.args[0] for call in send.call_args_list], ["/status", "/targets"])

    def test_paid_billing_refuses_audio_and_releases_any_attachment(self):
        paid = {**self.ready, "liveAuth": "api"}
        with patch.object(self.call, "send", side_effect=[self.ready, self.catalog, self.bound, paid, {}]) as send:
            with self.assertRaisesRegex(TalkError, "^subscription$"):
                self.call.start("test-chat", "v=0 offer")
            self.call.close()
        self.assertEqual([call.args[0] for call in send.call_args_list], [
            "/status", "/targets", "/native/attach", "/status", "/close",
        ])
