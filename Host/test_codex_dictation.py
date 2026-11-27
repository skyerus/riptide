import base64
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

from codex_dictation import MAX_AUDIO, codex_login, DictationError, reply


class CodexDictationTests(unittest.IsolatedAsyncioTestCase):
    async def test_only_a_bounded_audio_frame_reaches_the_transcriber(self):
        short_audio = b"\x00\x00\x00\x18ftypM4A "
        audio = short_audio.ljust(MAX_AUDIO, b"\x00")
        clip = base64.b64encode(audio).decode()
        oversized = base64.b64encode(audio + b"\x00").decode()
        with patch("codex_dictation.transcribe", new_callable=AsyncMock, return_value="Fixture dictation.") as upstream:
            for request in ({"audio": base64.b64encode(short_audio).decode(), "url": "https://example.test"},
                            {"audio": "?"}, {"audio": "YQ=="}, {"audio": oversized}, []):
                self.assertEqual(await reply(json.dumps(request), "/codex/auth.json"), {"error": "invalidAudio"})
            upstream.assert_not_called()
            self.assertEqual(await reply(json.dumps({"audio": clip}), "/codex/auth.json"),
                             {"text": "Fixture dictation."})
            upstream.assert_awaited_once_with(audio, "/codex/auth.json", None)

    def test_accepts_only_a_private_chatgpt_login_and_checks_bound_identity(self):
        account = "test-account"
        email = "fixture@example.test"
        fingerprint = base64.b64encode(hashlib.sha256(f"{account}\0{email}".encode()).digest()).decode()
        claims = base64.urlsafe_b64encode(json.dumps({"email": email}).encode()).decode().rstrip("=")
        with tempfile.TemporaryDirectory() as directory:
            auth_file = Path(directory) / "auth.json"
            auth = {"auth_mode": "chatgpt", "tokens": {
                "access_token": "fixture-token", "account_id": account, "id_token": f"a.{claims}.b",
            }}
            auth_file.write_text(json.dumps(auth))
            auth_file.chmod(0o600)
            self.assertEqual(codex_login(auth_file, fingerprint), ("fixture-token", account))
            with self.assertRaisesRegex(DictationError, "accountChanged"):
                codex_login(auth_file, "A" * 43 + "=")
            auth["auth_mode"] = "apikey"
            auth_file.write_text(json.dumps(auth))
            with self.assertRaisesRegex(DictationError, "signIn"):
                codex_login(auth_file, fingerprint)
