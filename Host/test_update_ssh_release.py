from contextlib import redirect_stdout
import io
from pathlib import Path
import runpy
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

from update_ssh_release import HOST, PAYLOAD, stage, update, verify


class SSHReleaseTests(unittest.TestCase):
    def test_shared_voice_migration_is_atomic_and_leaves_unrelated_keys_alone(self):
        enable_pairings = runpy.run_path(str(HOST / "deploy" / "stage-hermes-voice.py"))["enable_pairings"]
        home = Path(self.enterContext(tempfile.TemporaryDirectory()))
        keys = home / "authorized_keys"
        hermes = home / "hermes"
        old = home / "old" / "ssh_acp.py"
        new = home / "new" / "ssh_acp.py"
        config = home / "talk.json"
        old_config = home / "device-voice.json"

        def entry(label, command, options=()):
            identity = home / label
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(identity)], check=True)
            key = " ".join(identity.with_suffix(".pub").read_text().split()[:2])
            argv = [sys.executable, str(old), "--workspace", str(home), *options, "--", *command]
            return f'from="192.0.2.1",restrict,command="{shlex.join(argv)}" {key} {label}\r\n'

        primary = entry("primary", [str(hermes.with_name("hermes-acp"))],
                        ["--hermes-talk-config", str(old_config)])
        named = entry("named", [str(hermes), "-p", "accountant", "acp"])
        other = entry("other", [str(home / "other-agent"), "acp"])
        original = (primary + named + other).encode()
        keys.write_bytes(original)
        keys.chmod(0o600)

        failing_check = Mock(side_effect=[None, ValueError()])
        with patch.dict(enable_pairings.__globals__, {"verify": failing_check}):
            with self.assertRaisesRegex(ValueError, "Voice readiness check failed"):
                enable_pairings(keys, hermes, new, config)
        self.assertEqual(failing_check.call_count, 2)
        self.assertEqual(keys.read_bytes(), original)
        self.assertEqual(list(home.glob("*.before")), [])

        verify_result = Mock()
        with patch.dict(enable_pairings.__globals__, {"verify": verify_result}):
            self.assertEqual(enable_pairings(keys, hermes, new, config), 2)
            self.assertEqual(enable_pairings(keys, hermes, new, config), 2)
        self.assertEqual(verify_result.call_count, 4)
        self.assertTrue(all(call.kwargs == {"verify_talk": True} for call in verify_result.call_args_list))
        expected = (primary.replace(str(old), str(new)).replace(str(old_config), str(config))
                    + named.replace(str(old), str(new)).replace(" -- ", f" --hermes-talk-config {config} -- ") + other)
        self.assertEqual(keys.read_bytes(), expected.encode())
        backup, = home.glob("*.before")
        self.assertEqual(backup.read_bytes(), original)
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)

    def test_staged_pairing_runs_with_only_the_versioned_host_payload(self):
        home = Path(self.enterContext(tempfile.TemporaryDirectory()))
        wrapper = stage(home, "b" * 40)
        config = home / "pairing.json"
        config.write_text('{"targets":{"bookkeeper":{"name":"Bookkeeper"}}}')
        real_run = subprocess.run

        def run(argv, **kwargs):
            if kwargs.get("env", {}).get("SSH_ORIGINAL_COMMAND") == "riptide-hermes-screen":
                return subprocess.CompletedProcess(argv, 0, stdout="")
            return real_run(argv, **kwargs)

        with patch("update_ssh_release.subprocess.run", side_effect=run):
            verify([sys.executable, str(wrapper), "--workspace", str(home),
                    "--hermes-screen", str(home), sys.executable,
                    "--pairing-config", str(config), "--", sys.executable])

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
        index = argv.index("--safari")
        del argv[index:index + 3]
        self.assertEqual([call.args[0] for call in verify.call_args_list], [argv, argv])
        expected = original.replace(str(old), str(new)).replace(" --safari /relay/browser.sock device", "")
        self.assertEqual(keys.read_bytes(), expected.encode())
        self.assertEqual(keys.stat().st_mode & 0o777, 0o600)
        for name in PAYLOAD:
            self.assertEqual((new.parent / name).read_bytes(), (HOST / name).read_bytes())

        with patch("update_ssh_release.verify") as verify, redirect_stdout(io.StringIO()):
            update(keys, fingerprint, releases, previous, revision, enable_hermes_groups=True)
            update(keys, fingerprint, releases, previous, revision, enable_hermes_groups=True)
        boundary = argv.index("--")
        argv[boundary:boundary] = ["--hermes-groups", "/profile", "/bin/hermes"]
        self.assertEqual([call.args[0] for call in verify.call_args_list], [argv, argv])

    def test_dictation_is_enabled_and_verified_only_for_the_selected_key(self):
        home = Path(self.enterContext(tempfile.TemporaryDirectory()))
        keys = home / "authorized_keys"
        releases = home / "releases"
        releases.mkdir()
        previous, revision = "a" * 40, "b" * 40
        old = releases / previous / "Host" / "ssh_acp.py"
        command = shlex.join([sys.executable, str(old), "--workspace", str(home), "--", sys.executable])
        entries = []
        fingerprints = []
        for name in ("accountant", "primary"):
            identity = home / name
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(identity)], check=True)
            public = identity.with_suffix(".pub")
            entries.append(f'restrict,command="{command}" {public.read_text()}')
            fingerprints.append(subprocess.check_output(["ssh-keygen", "-lf", str(public)], text=True).split()[1])
        keys.write_text("".join(entries))
        auth = home / "auth.json"
        auth.write_text("{}")
        auth.chmod(0o640)

        with self.assertRaisesRegex(ValueError, "mode-0600"):
            update(keys, fingerprints[0], releases, previous, revision, codex_dictation_auth=auth)
        self.assertEqual(keys.read_text(), "".join(entries))

        auth.chmod(0o600)
        with redirect_stdout(io.StringIO()):
            update(keys, fingerprints[0], releases, previous, revision, codex_dictation_auth=auth)
            update(keys, fingerprints[0], releases, previous, revision, codex_dictation_auth=auth)
        selected = entries[0].replace(str(old), str(releases / revision / "Host" / "ssh_acp.py"))
        selected = selected.replace(" -- ", f" --codex-dictation-auth {shlex.quote(str(auth))} -- ")
        self.assertEqual(keys.read_text(), selected + entries[1])

    def test_versioned_update_can_enable_pairing_for_only_the_selected_key(self):
        home = Path(self.enterContext(tempfile.TemporaryDirectory()))
        phone = home / "phone"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(phone)], check=True)
        public_key = phone.with_suffix(".pub").read_text().strip()
        fingerprint = subprocess.check_output(["ssh-keygen", "-lf", str(phone.with_suffix(".pub"))],
                                              text=True).split()[1]
        releases = home / "releases"
        releases.mkdir()
        old = releases / ("a" * 40) / "Host" / "ssh_acp.py"
        argv = [sys.executable, str(old), "--workspace", "/work", "--hermes-screen",
                "/profile", "/bin/hermes", "--", "/bin/agent"]
        keys = home / "authorized_keys"
        keys.write_text(f'restrict,command="{shlex.join(argv)}" {public_key}\n# do not change\n')
        config = home / "pairing.json"
        config.write_text('{"targets": {}}')
        with patch("update_ssh_release.verify") as verify, redirect_stdout(io.StringIO()):
            update(keys, fingerprint, releases, "a" * 40, "b" * 40, pairing_config=config)
        command = verify.call_args.args[0]
        self.assertEqual(command[command.index("--pairing-config") + 1], str(config))
        self.assertLess(command.index("--pairing-config"), command.index("--"))
        self.assertTrue(keys.read_text().endswith("# do not change\n"))


    def test_new_screen_and_computer_use_are_enabled_together_for_the_selected_key(self):
        home = Path(self.enterContext(tempfile.TemporaryDirectory()))
        phone = home / "phone"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(phone)], check=True)
        public_key = phone.with_suffix(".pub").read_text().strip()
        fingerprint = subprocess.check_output(["ssh-keygen", "-lf", str(phone.with_suffix(".pub"))],
                                              text=True).split()[1]
        releases = home / "releases"
        releases.mkdir()
        previous, revision = "a" * 40, "b" * 40
        old = releases / previous / "Host" / "ssh_acp.py"
        command = [sys.executable, str(old), "--workspace", "/work", "--", "/bin/agent"]
        keys = home / "authorized_keys"
        keys.write_text(f'restrict,command="{shlex.join(command)}" {public_key}\n')
        expected = ["--hermes-screen", str(home.resolve()), sys.executable,
                    "--hermes-browser-mcp", sys.executable, str(home)]
        with patch("update_ssh_release.verify") as verified, redirect_stdout(io.StringIO()):
            for _ in range(2):
                update(keys, fingerprint, releases, previous, revision,
                       browser_mcp=(Path(sys.executable), home), hermes_screen=(home, Path(sys.executable)))
        self.assertEqual([call.args[0][4:-2] for call in verified.call_args_list], [expected, expected])

    def test_versioned_update_enables_name_tool_for_a_pairing_without_a_screen(self):
        home = Path(self.enterContext(tempfile.TemporaryDirectory()))
        phone = home / "phone"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(phone)], check=True)
        public_key = phone.with_suffix(".pub").read_text().strip()
        fingerprint = subprocess.check_output(["ssh-keygen", "-lf", str(phone.with_suffix(".pub"))],
                                              text=True).split()[1]
        releases = home / "releases"
        releases.mkdir()
        old = releases / ("a" * 40) / "Host" / "ssh_acp.py"
        argv = [sys.executable, str(old), "--workspace", str(home), "--", sys.executable]
        keys = home / "authorized_keys"
        keys.write_text(f'restrict,command="{shlex.join(argv)}" {public_key}\n')
        state = home / "name.json"
        with redirect_stdout(io.StringIO()):
            update(keys, fingerprint, releases, "a" * 40, "b" * 40, agent_profile_state=state)
        self.assertIn(f"--agent-profile-state {state} --", keys.read_text())
        self.assertFalse(state.exists(), "Release verification must leave the state untouched.")
