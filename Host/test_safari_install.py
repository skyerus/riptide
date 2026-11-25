import argparse
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import select
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import yaml

import install_safari as installer
from safari_bridge import agent_call


class UserServices:
    """Run real relay children behind the systemctl operations used by the installer."""

    def __init__(self, directory):
        self.directory = directory
        self.services = {}
        self.enabled = set()
        self.calls = []

    def __call__(self, action, *args, check=True):
        self.calls.append((action, *args))
        name = args[-1] if args else None
        current = self.services.get(name)
        status = 0
        if action == "is-active":
            status = 0 if current and current.poll() is None else 3
        elif action == "is-enabled":
            status = 0 if name in self.enabled else 1
        elif action == "enable":
            self.enabled.add(name)
        elif action == "disable":
            self.enabled.discard(name)
        elif action == "stop":
            self.stop(name)
        elif action in {"start", "restart"}:
            self.stop(name)
            unit = (self.directory / name).read_text()
            command = next(line.removeprefix("ExecStart=:") for line in unit.splitlines()
                           if line.startswith("ExecStart=:"))
            self.services[name] = subprocess.Popen(shlex.split(command.replace("%%", "%")),
                                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        elif action not in {"show-environment", "daemon-reload"}:
            raise AssertionError(f"Unexpected systemctl action {action}")
        return subprocess.CompletedProcess([action, *args], status, "", "")

    def stop(self, name):
        process = self.services.pop(name, None)
        if process and process.poll() is None:
            process.terminate()
            process.wait(timeout=5)

    def close(self):
        for name in list(self.services):
            self.stop(name)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="rsi-", dir="/tmp")
        self.addCleanup(directory.cleanup)
        self.home = Path(directory.name)
        self.workspace = self.home / "agent workspace"
        self.workspace.mkdir()
        self.keys = self.home / ".ssh" / "authorized_keys"
        self.keys.parent.mkdir(mode=0o700)
        self.profile = self.home / ".hermes" / "config.yaml"
        self.profile.parent.mkdir(mode=0o700)
        self.profile.write_text("# Existing profile\nmodel:\n  openai_runtime: auto\n")
        self.profile.chmod(0o600)
        self.public = self.make_key("phone")
        self.other = self.make_key("other")
        self.services = UserServices(self.home / ".config" / "systemd" / "user")
        self.addCleanup(self.services.close)
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, {"XDG_CONFIG_HOME": str(self.home / ".config")}).start()
        patch.object(installer, "systemctl", self.services).start()
        # The Python environment is preinstalled in this fixture. Stage the real host files.
        real_run = subprocess.run

        def run(arguments, **kwargs):
            if arguments[:3] == [sys.executable, "-m", "venv"]:
                target = Path(arguments[-1]) / "bin"
                target.mkdir(parents=True)
                (target / "python").symlink_to(sys.executable)
                return subprocess.CompletedProcess(arguments, 0)
            if arguments[1:4] == ["-m", "pip", "install"] or arguments[1:] == ["-c", "import mcp, yaml"]:
                return subprocess.CompletedProcess(arguments, 0)
            return real_run(arguments, **kwargs)

        patch.object(installer.subprocess, "run", side_effect=run).start()
        self.agent = self.home / "hermes-acp"
        self.agent.write_text(f"""#!{sys.executable}
import json, os, sys
for line in sys.stdin:
    packet = json.loads(line)
    print(json.dumps({{"params": packet["params"], "scope": os.environ.get("{installer.STATE_ENV}")}}), flush=True)
""")
        self.agent.chmod(0o700)
        self.before_line = self.line(self.public)
        self.other_line = self.line(self.other)
        self.keys.write_bytes((self.before_line + self.other_line + "# End\r\n").encode())
        self.keys.chmod(0o600)

    def make_key(self, name):
        path = self.home / name
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(path)], check=True)
        return path.with_suffix(".pub").read_text().strip()

    def line(self, public):
        argv = [sys.executable, "-B", "/opt/old/ssh_acp.py", "--workspace", str(self.workspace),
                "--hermes-screen", str(self.profile.parent), "/opt/hermes",
                "--codex-dictation-auth", "/opt/codex/auth.json", "--", str(self.agent)]
        forced = shlex.join(argv)
        return f'  from="192.0.2.1,192.0.2.2",restrict,command="{forced}"   {public}\r\n'

    def run_install(self, public=None, runtime="hermes", config=None):
        arguments = argparse.Namespace(key=public or self.public, runtime=runtime,
                                       authorized_keys=None, hermes_config=config)
        output = io.StringIO()
        with redirect_stdout(output):
            installer.install(arguments, self.home)
        return output.getvalue()

    def forced(self, public=None):
        key, _ = installer.key_identity(public or self.public)
        source = self.keys.read_bytes().decode()
        _, _, prefix, _, agent = installer.key_command(source, key)
        return prefix, agent

    def load_chat(self, prefix, agent):
        process = subprocess.Popen([*prefix, "--", *agent], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                                   env={**os.environ, "SSH_ORIGINAL_COMMAND": "riptide-acp"})
        try:
            process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "session/load", "params": {
                "cwd": str(self.workspace), "sessionId": "test", "mcpServers": [],
            }}) + "\n")
            process.stdin.flush()
            self.assertTrue(select.select([process.stdout], [], [], 5)[0])
            return json.loads(process.stdout.readline())
        finally:
            process.stdin.close()
            process.stdout.close()
            process.wait(timeout=5)

    def test_existing_hermes_pairing_and_safe_rerun(self):
        original_config = self.profile.read_bytes()
        self.run_install()
        once = self.keys.read_bytes()
        self.assertTrue(once.endswith((self.other_line + "# End\r\n").encode()))
        self.assertTrue(once.startswith(b'  from="192.0.2.1,192.0.2.2",restrict,command="'))
        self.assertEqual(self.keys.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.profile.read_bytes(), original_config)
        prefix, agent = self.forced()
        self.assertIn("--hermes-screen", prefix)
        self.assertIn("--codex-dictation-auth", prefix)
        socket = Path(prefix[prefix.index("--safari") + 1])
        self.assertEqual(socket.stat().st_mode & 0o777, 0o600)
        self.assertEqual(socket.parent.stat().st_mode & 0o777, 0o700)
        reply = self.load_chat(prefix, agent)
        connector, = reply["params"]["mcpServers"]
        self.assertEqual(connector["name"], "riptide_safari")
        self.assertEqual(connector["args"][1:], ["--state-dir", str(socket.parent)])
        self.services.calls.clear()
        self.run_install()
        self.assertEqual(self.keys.read_bytes(), once)
        self.assertFalse({"enable", "start", "restart", "daemon-reload"} &
                         {action for action, *_ in self.services.calls})

    def test_codex_launcher_scopes_two_pairings_and_preserves_other_invocations(self):
        codex = self.home / "original codex"
        codex.write_text(f'#!{sys.executable}\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n')
        codex.chmod(0o700)
        before = f"# Keep comment\nmodel:\n  openai_runtime: codex_app_server\n  codex_bin: {codex} # keep\nprovider: keep\n"
        self.profile.write_text(before)
        output = self.run_install()
        self.assertIn("persistent Hermes gateway", output)
        config_installed = self.profile.read_text()
        launcher = yaml.safe_load(config_installed)["model"]["codex_bin"]
        self.assertIn("# keep\n", config_installed)
        self.assertEqual(config_installed.replace(json.dumps(launcher), str(codex)), before)
        self.run_install(self.other)
        self.assertEqual(self.profile.read_text(), config_installed)
        self.run_install()
        self.assertEqual(self.profile.read_text(), config_installed)
        scopes = []
        for public in (self.public, self.other):
            prefix, agent = self.forced(public)
            reply = self.load_chat(prefix, agent)
            scope = reply["scope"]
            scopes.append(scope)
            python = reply["params"]["mcpServers"][0]["command"]
            configured = subprocess.check_output([launcher, "app-server"], text=True, env={
                **os.environ, installer.PYTHON_ENV: python, installer.STATE_ENV: scope,
            })
            self.assertIn("mcp_servers.riptide_safari.args=", configured)
            self.assertIn(scope, configured)
        self.assertNotEqual(*scopes)
        self.assertEqual(json.loads(subprocess.check_output([launcher, "app-server"], text=True)), ["app-server"])

    def test_stdio_configuration_uses_the_real_relay_without_hermes_changes(self):
        self.profile.unlink()
        output = self.run_install(runtime="stdio")
        prefix, agent = self.forced()
        self.assertEqual(self.load_chat(prefix, agent)["params"]["mcpServers"], [])
        state = Path(prefix[prefix.index("--safari") + 1]).parent
        self.assertIn('"riptide_safari"', output)
        self.assertIn(str(state), output)
        proof = agent_call(state, "request", url="https://example.invalid/")
        self.assertEqual(proof["url"], "https://example.invalid/")
        self.assertEqual(agent_call(state, "finish", request_id=proof["request_id"])["state"], "finished")

    def test_failed_verification_rolls_back_unit_and_leaves_existing_key_untouched(self):
        before = self.keys.read_bytes()
        with patch.object(installer, "verify_ssh_route", side_effect=ValueError("fixture failure")):
            with self.assertRaisesRegex(ValueError, "fixture failure"):
                self.run_install()
        self.assertEqual(self.keys.read_bytes(), before)
        self.assertEqual(list(self.services.directory.glob("*.service")), [])
        self.assertEqual(self.services.services, {})
        self.assertEqual(self.services.enabled, set())
        self.run_install()

    def test_failed_key_update_restores_the_codex_profile(self):
        source = f"model: {{openai_runtime: codex_app_server, codex_bin: {sys.executable}}}\n"
        self.profile.write_text(source)
        before = self.keys.read_bytes()
        edit_file = installer.Edit.apply

        def fail_key_edit(edit, *args):
            if edit.path == self.keys:
                raise ValueError("fixture key change")
            return edit_file(edit, *args)

        with patch.object(installer.Edit, "apply", fail_key_edit):
            with self.assertRaisesRegex(ValueError, "fixture key change"):
                self.run_install()
        self.assertEqual(self.profile.read_text(), source)
        self.assertEqual(self.keys.read_bytes(), before)
        self.assertEqual(self.services.enabled, set())

    def test_refuses_duplicate_or_unrestricted_key_before_installation(self):
        for candidate in (self.before_line * 2, self.public + "\n" + self.before_line,
                          self.before_line.replace(",restrict,", ",")):
            with self.subTest(candidate=candidate):
                self.keys.write_bytes(candidate.encode())
                with self.assertRaises(ValueError):
                    self.run_install()
                self.assertEqual(self.keys.read_bytes(), candidate.encode())
                self.assertEqual(self.services.enabled, set())

    def test_existing_manual_route_is_preserved(self):
        manual = self.before_line.replace(" -- ", " --safari /tmp/manual/browser.sock existing-device-id -- ")
        self.keys.write_bytes(manual.encode())
        with self.assertRaisesRegex(ValueError, "already uses a different Safari relay"):
            self.run_install()
        self.assertEqual(self.keys.read_bytes(), manual.encode())
        self.assertEqual(self.services.enabled, set())


if __name__ == "__main__":
    unittest.main()
