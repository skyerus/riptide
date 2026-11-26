from pathlib import Path
import sys
import tempfile
import unittest

from ruamel.yaml import YAML

from configure_hermes_codex import configure


class ConfigureHermesCodexTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.home = Path(directory.name)
        self.binary = str(Path(sys.executable).resolve())
        self.codex = self.home / "codex.toml"
        self.codex.write_text(
            'default_permissions = ":workspace"\n'
            'approval_policy = "on-request"\n'
            'approvals_reviewer = "auto_review"\n'
        )
        self.default = self.home / "config.yaml"
        self.default.write_text(f"model:\n  provider: openai-codex\n  codex_bin: {self.binary}\n")
        self.accountant = self.home / "profiles/accountant/config.yaml"
        self.accountant.parent.mkdir(parents=True)
        self.accountant.write_text(
            "# Profile settings\nmodel: {provider: openai-codex, default: gpt-6.2-sol, openai_runtime: auto}\n"
            "terminal: {backend: local}\n"
        )

    def test_updates_root_and_named_profiles_without_disturbing_other_settings(self):
        original = self.accountant.read_bytes()
        self.assertTrue(all(profile["changed"] for profile in configure(self.home, self.codex, self.binary)))
        self.assertEqual(self.accountant.read_bytes(), original)

        configure(self.home, self.codex, self.binary, apply=True)

        yaml = YAML(typ="safe")
        default = yaml.load(self.default.read_text())
        named = yaml.load(self.accountant.read_text())
        self.assertEqual(default["model"]["openai_runtime"], "codex_app_server")
        self.assertEqual(named, {
            "model": {"provider": "openai-codex", "default": "gpt-6.2-sol",
                      "openai_runtime": "codex_app_server", "codex_bin": self.binary},
            "terminal": {"backend": "local"},
        })
        self.assertIn("# Profile settings", self.accountant.read_text())
        self.assertFalse(any(profile["changed"] for profile in configure(self.home, self.codex, self.binary)))

    def test_incompatible_profile_leaves_the_default_unchanged(self):
        original = self.default.read_bytes()
        self.accountant.write_text("model: {provider: anthropic}\n")
        with self.assertRaisesRegex(ValueError, "Codex-compatible model provider"):
            configure(self.home, self.codex, self.binary, apply=True)
        self.assertEqual(self.default.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
