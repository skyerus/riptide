from contextlib import redirect_stdout
import io
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from install_safari import HOST, PAYLOAD
from update_ssh_release import update


class SSHReleaseTests(unittest.TestCase):
    def test_verifies_before_switching_and_preserves_the_pairing(self):
        home = Path(self.enterContext(tempfile.TemporaryDirectory()))
        identity = home / "phone"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(identity)], check=True)
        public_key = identity.with_suffix(".pub").read_text().strip()
        fingerprint = subprocess.check_output(["ssh-keygen", "-lf", str(identity.with_suffix(".pub"))],
                                              text=True).split()[1]
        releases = home / "releases"
        releases.mkdir()
        previous, revision = "a" * 40, "b" * 40
        old = releases / previous / "Host" / "ssh_acp.py"
        new = releases / revision / "Host" / "ssh_acp.py"
        argv = [sys.executable, "-B", str(old), "--workspace", "/work tree", "--hermes-screen",
                "/profile", "/bin/hermes", "--safari", "/relay/browser.sock", "device", "--", "/bin/agent"]
        keys = home / "authorized_keys"
        original = f'from="192.0.2.1",restrict,command="{shlex.join(argv)}" {public_key}\r\n# keep\r\n'
        keys.write_bytes(original.encode())
        keys.chmod(0o600)

        with patch("update_ssh_release.verify", side_effect=ValueError("failed check")):
            with self.assertRaisesRegex(ValueError, "failed check"):
                update(keys, fingerprint, releases, previous, revision)
        self.assertEqual(keys.read_bytes(), original.encode())

        with patch("update_ssh_release.verify") as verify, redirect_stdout(io.StringIO()):
            update(keys, fingerprint, releases, previous, revision)
            update(keys, fingerprint, releases, previous, revision)
        argv[2] = str(new)
        self.assertEqual([call.args[0] for call in verify.call_args_list], [argv, argv])
        self.assertEqual(keys.read_bytes(), original.replace(str(old), str(new)).encode())
        self.assertEqual(keys.stat().st_mode & 0o777, 0o600)
        for name in PAYLOAD:
            self.assertEqual((new.parent / name).read_bytes(), (HOST / name).read_bytes())
