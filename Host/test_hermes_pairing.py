import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


class HermesPairingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.workspace = self.root / "workspace"
        self.workspace.mkdir()
        self.keys = self.root / "authorized_keys"
        self.keys.write_text("# Existing keys are preserved\n")
        self.key_path = self.root / "device"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(self.key_path)], check=True)
        self.public_key = " ".join(self.key_path.with_suffix(".pub").read_text().split()[:2])
        self.wrapper = Path(__file__).with_name("ssh_acp.py").resolve()
        self.chat_id = "main"
        self.agent = self.root / "hermes"
        self.agent.write_text(f"""#!{sys.executable}
import json, sys
for line in sys.stdin:
    frame = json.loads(line)
    result = {{"protocolVersion": 1, "agentCapabilities": {{"loadSession": True, "sessionCapabilities": {{"list": {{}}}}}}}}
    if frame["method"] == "session/list":
        result = {{"sessions": [{{"sessionId": {self.chat_id!r}, "cwd": {str(self.workspace)!r}}}]}}
    print(json.dumps({{"jsonrpc": "2.0", "id": frame["id"], "result": result}}), flush=True)
""")
        self.agent.chmod(0o700)
        self.routes = self.root / "routes.json"
        self.routes.write_text(json.dumps({"authorizedKeys": str(self.keys), "hermes": str(self.agent),
            "targets": {"accountant": {"name": "Accountant", "workspace": str(self.workspace),
                                       "mainSessionID": self.chat_id}}}))

    def request(self, profile="accountant", key=None, enabled=True):
        flags = ["--pairing-config", str(self.routes)] if enabled else []
        result = subprocess.run(
            [sys.executable, str(self.wrapper), "--workspace", str(self.workspace),
             *flags, "--", sys.executable],
            env={**os.environ, "SSH_ORIGINAL_COMMAND": "riptide-pair-hermes"},
            input=json.dumps({"profile": profile, "publicKey": key or self.public_key}) + "\n",
            capture_output=True, text=True, timeout=12,
        )
        return result, json.loads(result.stdout) if result.stdout else {}

    def test_approved_device_key_is_limited_to_the_selected_hermes_profile(self):
        completed, reply = self.request()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(reply, {"name": "Accountant", "workspace": str(self.workspace), "mainSessionID": self.chat_id})
        lines = self.keys.read_text().splitlines()
        self.assertEqual(lines[0], "# Existing keys are preserved")
        prefix, key = lines[1].split(" ssh-ed25519 ")
        self.assertTrue(prefix.startswith('restrict,command="'))
        self.assertEqual(shlex.split(prefix[len('restrict,command="'):-1]),
            [sys.executable, str(self.wrapper), "--workspace", str(self.workspace), "--",
             str(self.agent), "-p", "accountant", "acp"])
        self.assertTrue(self.public_key.endswith(key.split()[0]))

    def test_retry_does_not_duplicate_an_authorized_key(self):
        self.assertEqual(self.request()[0].returncode, 0)
        authorized = self.keys.read_text()
        self.assertEqual(self.request()[0].returncode, 0)
        self.assertEqual(self.keys.read_text(), authorized)

    def test_unconfigured_target_does_not_register_a_key(self):
        self.assertIn("error", self.request(profile="not-allowed")[1])
        self.assertNotIn(self.public_key, self.keys.read_text())

    def test_unlisted_main_chat_does_not_register_a_key(self):
        config = json.loads(self.routes.read_text())
        config["targets"]["accountant"]["mainSessionID"] = "unlisted"
        self.routes.write_text(json.dumps(config))
        self.assertIn("error", self.request()[1])
        self.assertNotIn(self.public_key, self.keys.read_text())

    def test_key_is_not_registered_from_a_pairing_without_broker_access(self):
        self.assertNotEqual(self.request(enabled=False)[0].returncode, 0)
        self.assertNotIn(self.public_key, self.keys.read_text())
