import base64
import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from attention_relay import APNs, AttentionEvent, AttentionState, Relay


DEVICE = "01234567-89ab-4cde-8123-456789abcdef"
CLIENT = "c" * 40
PUBLISHER = "p" * 40


class AttentionRelayTests(unittest.TestCase):
    def setUp(self):
        self.now = 1000
        self.sent = []
        self.state = AttentionState(clock=lambda: self.now, send=self.deliver)
        self.state.register({
            "id": DEVICE, "token": "ab" * 32, "environment": "development",
            "policy": {"delivery": "whenAway", "approvals": True, "replies": False},
        })

    def deliver(self, device, event):
        self.sent.append((device["id"], event.chat, event.reason))
        return "sent"

    def event(self, reason="approval", **overrides):
        return {"workspace": "agent", "chat": "main", "eventID": "attempt1", "reason": reason, **overrides}

    def presence(self, active, workspace="agent"):
        self.state.report_presence({"workspace": workspace, "active": active})

    def test_delays_while_active_then_sends_once_when_away(self):
        self.presence(True)
        self.state.publish(self.event())
        self.state.flush()
        self.assertEqual(self.sent, [])
        self.presence(False)
        self.now += 12
        self.state.flush()
        self.state.publish(self.event())
        self.state.flush()
        self.assertEqual(self.sent, [(DEVICE, "main", "approval")])

    def test_stale_presence_and_reply_preferences(self):
        self.presence(True)
        self.state.publish(self.event("reply"))
        self.state.publish(self.event())
        self.now += 46
        self.state.flush()
        self.assertEqual(self.sent, [(DEVICE, "main", "approval")])

    def test_an_approval_resolved_at_the_desktop_is_not_pushed_later(self):
        self.presence(True)
        self.state.publish(self.event())
        self.state.publish(self.event(state="resolved"))
        self.now += 46
        self.state.flush()
        self.assertEqual(self.sent, [])
        self.assertEqual(self.state.entries(), [])

    def test_delayed_resolution_cannot_hide_a_newer_approval_in_the_same_chat(self):
        self.presence(True)
        self.state.publish(self.event(eventID="first"))
        self.state.publish(self.event(eventID="replacement"))
        self.state.publish(self.event(eventID="first", state="resolved"))
        self.assertEqual([row["eventID"] for row in self.state.entries()], ["replacement"])
        self.presence(False)
        self.now += 12
        self.state.flush()
        self.assertEqual(self.sent, [(DEVICE, "main", "approval")])

    def test_short_focus_change_does_not_alert_until_desktop_is_actually_away(self):
        self.presence(True)
        self.state.publish(self.event())
        self.now += 5
        self.presence(False)
        self.state.flush()
        self.assertEqual(self.sent, [])
        self.now += 4
        self.presence(True)
        self.state.flush()
        self.assertEqual(self.sent, [])
        self.now += 8
        self.presence(False)
        self.now += 8
        self.state.flush()
        self.assertEqual(self.sent, [(DEVICE, "main", "approval")])

    def test_active_work_desktop_does_not_mute_another_workspace(self):
        self.presence(True, "work-codex")
        self.presence(False, "home-codex")
        self.state.publish(self.event(workspace="work-codex", chat="at-work"))
        self.state.publish(self.event(workspace="home-codex", chat="at-home"))
        self.state.publish(self.event(workspace="hermes", chat="on-server"))
        self.state.flush()
        self.assertEqual(self.sent, [(DEVICE, "at-home", "approval"), (DEVICE, "on-server", "approval")])
        self.presence(False, "work-codex")
        self.now += 12
        self.state.flush()
        self.assertEqual(self.sent[-1], (DEVICE, "at-work", "approval"))

    def test_resolution_received_before_an_activation_prevents_a_stale_alert(self):
        self.state.publish(self.event(state="resolved"))
        self.state.publish(self.event())
        self.state.flush()
        self.assertEqual(self.sent, [])
        self.assertEqual(self.state.entries(), [])

    def test_registration_is_private_and_can_be_revoked(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "devices.json"
            self.state.device_file = path
            self.state.persist()
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            restored = AttentionState(clock=lambda: self.now, send=self.deliver, device_file=path)
            restored.remove(DEVICE)
            self.assertEqual(json.loads(path.read_text()), {})

    def test_read_and_publish_credentials_cannot_impersonate_each_other(self):
        with Relay(0, self.state, CLIENT, PUBLISHER) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = f"http://127.0.0.1:{server.server_port}"
            try:
                def send(path, bearer, body=None):
                    headers = {"Authorization": f"Bearer {bearer}"}
                    data = None if body is None else json.dumps(body).encode()
                    with urllib.request.urlopen(urllib.request.Request(base + path, data, headers), timeout=3) as response:
                        return json.load(response)
                with self.assertRaises(urllib.error.HTTPError) as denied:
                    send("/v1/presence", CLIENT, {"active": True})
                self.assertEqual(denied.exception.code, 401)
                self.assertTrue(send("/v1/presence", PUBLISHER, {"active": True, "workspace": "work-codex"})["ok"])
                self.assertTrue(send("/v1/presence", CLIENT)["active"])
                self.assertTrue(send("/v1/presence?workspace=work-codex", CLIENT)["active"])
                self.assertIsNone(send("/v1/presence?workspace=hermes", CLIENT))
                with self.assertRaises(urllib.error.HTTPError) as malformed:
                    send("/v1/presence?workspace=one&workspace=two", CLIENT)
                self.assertEqual(malformed.exception.code, 400)
                with self.assertRaises(urllib.error.HTTPError) as denied:
                    send("/v1/presence", PUBLISHER)
                self.assertEqual(denied.exception.code, 401)
            finally:
                server.shutdown()
                thread.join(3)

    def test_apns_signs_the_request_and_only_previews_reply_events(self):
        try:
            import httpx
            from cryptography.hazmat.primitives import hashes, serialization
            from cryptography.hazmat.primitives.asymmetric import ec
            from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
        except ImportError:
            self.skipTest("Install the optional attention requirements to exercise APNs signing.")
        key = ec.generate_private_key(ec.SECP256R1())
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "example.p8"
            path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                               serialization.NoEncryption()))
            path.chmod(0o600)
            sender = APNs(team="EXAMPLE001", key_id="EXAMPLE002", topic="app.riptide.client", key_file=path)
        sender.client.close()

        preloading = False

        def inspect(request):
            self.assertEqual(request.url.host, "api.sandbox.push.apple.com")
            self.assertEqual(request.headers["apns-topic"], "app.riptide.client")
            self.assertEqual(request.headers["apns-push-type"], "alert")
            self.assertEqual(len(request.headers["apns-collapse-id"]), 64)
            headers, claims, encoded = request.headers["authorization"].removeprefix("Bearer ").split(".")
            raw = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
            signature = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
            key.public_key().verify(signature, f"{headers}.{claims}".encode(), ec.ECDSA(hashes.SHA256()))
            payload = json.loads(request.content)
            expected_payload = {
                "aps": {"alert": {"title": "Riptide", "body": expected}, "sound": "default"},
                "workspace": "agent", "chat": "main",
            }
            if preloading:
                expected_payload["aps"]["mutable-content"] = 1
                expected_payload["replyEventID"] = event.event_id
            self.assertEqual(payload, expected_payload)
            return httpx.Response(200)

        with httpx.Client(transport=httpx.MockTransport(inspect)) as client:
            sender.client = client
            for reason, preview, expected in (
                ("approval", "A private command", "Approval needed"),
                ("input", "A private question", "Waiting for your input"),
                ("reply", None, "Reply ready"),
                ("reply", " \r\n\t ", "Reply ready"),
                ("reply", "\n  Your update is ready.  \r\nThe rest of the reply.", "Your update is ready."),
                ("reply", "🙂" * 200 + "\nNext line.", "🙂" * 179 + "…"),
            ):
                with self.subTest(reason=reason, expected=expected):
                    body = self.event(reason) if preview is None else self.event(reason, preview=preview)
                    self.assertEqual(sender.send(self.state.devices[DEVICE], AttentionEvent.parse(body)), "sent")
            device = {**self.state.devices[DEVICE], "replyPreload": True}
            expected = "The report is ready."
            event = AttentionEvent.parse(self.event("reply", preview=expected) | {"replyRow": 23})
            preloading = True
            self.assertEqual(sender.send(device, event), "sent")
