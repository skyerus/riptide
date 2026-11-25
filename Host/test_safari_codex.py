import json
from pathlib import Path
import unittest

from safari_codex import command_with_safari


class SafariCodexTests(unittest.TestCase):
    def test_unconfigured_app_server_and_other_commands_delegate_unchanged(self):
        self.assertEqual(command_with_safari(["app-server"], None, None), ["app-server"])
        self.assertEqual(command_with_safari(["--version"], "/python", "/relay"), ["--version"])

    def test_configured_app_server_receives_only_the_scoped_safari_settings(self):
        original = ["app-server", "-c", "existing=true"]
        command = command_with_safari(original, "/private venv/bin/python", "/private relay")
        self.assertEqual(command[:len(original)], original)
        self.assertEqual(command[len(original)::2], ["-c"] * 3)
        added = dict(setting.split("=", 1) for setting in command[len(original) + 1::2])
        self.assertEqual({key: json.loads(value) for key, value in added.items()}, {
            "mcp_servers.riptide_safari.command": "/private venv/bin/python",
            "mcp_servers.riptide_safari.args": [
                str(Path(__file__).with_name("safari_mcp.py").resolve()), "--state-dir", "/private relay",
            ],
            "mcp_servers.riptide_safari.tool_timeout_sec": 90,
        })

    def test_incomplete_and_relative_scope_are_rejected(self):
        for python, state in ((None, "/relay"), ("/python", None), ("python", "/relay"), ("/python", "relay")):
            with self.subTest(python=python, state=state), self.assertRaises(ValueError):
                command_with_safari(["app-server"], python, state)
