"""Check batch SSH migration boundaries before deploying to the shared host."""
from importlib.util import module_from_spec, spec_from_file_location
import json
from pathlib import Path
import shlex
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from hermes_chrome_profile import SHARED_BROWSER, ChromePolicy, browser_route
from ssh_pairing_files import key_command

spec = spec_from_file_location("chrome_rollout", Path(__file__).parent / "deploy" / "enable-hermes-chrome.py")
rollout = module_from_spec(spec)
spec.loader.exec_module(rollout)


class ChromeRolloutTests(unittest.TestCase):
    def test_pairing_manifest_sharing_requires_opt_in_and_preserves_explicit_members(self):
        root = Path(self.enterContext(tempfile.TemporaryDirectory())).resolve()
        home, releases, profile = root / "hermes", root / "releases", root / "hermes/profiles/new-agent"
        profile.mkdir(parents=True)
        releases.mkdir()
        keys = root / "authorized_keys"
        keys.touch()
        manifest = home / "pairing.json"
        manifest.write_text(json.dumps({"hermes": sys.executable, "authorizedKeys": str(keys),
                                        "targets": {"new-agent": {}}}))
        sharing = home / SHARED_BROWSER
        config = {"owner": "default", "members": ["default", "explicit-member"]}
        sharing.write_text(json.dumps(config))
        args = SimpleNamespace(home=home, source=home, python=sys.executable, releases=releases,
                               manifest=manifest, revision="a" * 40, previous_releases=[], legacy_wrapper=None,
                               reload_gateway=False, share_with_pairable_agents=False)
        with (patch.object(rollout, "CHROME", sys.executable),
              patch.object(rollout, "stage", return_value=releases / "Host" / "ssh_acp.py"),
              patch.object(rollout, "key_edits", return_value=("", 1, {"default"})),
              patch.object(rollout, "profile_edits", return_value=[]),
              patch("builtins.print")):
            rollout.activate(args)
            self.assertEqual(json.loads(sharing.read_text()), config)
            self.assertIsNone(browser_route(profile).shared)
            args.share_with_pairable_agents = True
            rollout.activate(args)
            rollout.activate(args)
        self.assertEqual(json.loads(sharing.read_text()), {**config, "pairing_manifest": str(manifest)})
        self.assertEqual(browser_route(profile).shared.home, home)
        self.assertEqual(browser_route(home / "profiles/explicit-member").shared.home, home)

    def test_updates_legacy_and_versioned_hermes_keys_and_preserves_other_entries(self):
        home = Path(self.enterContext(tempfile.TemporaryDirectory()))
        (home / "profiles" / "agent").mkdir(parents=True)
        policy = ChromePolicy(home, Path("/usr/bin/python3"), home)
        hermes = Path("/bin/hermes")
        older = home / "releases"
        prior = older / ("a" * 40) / "Host" / "ssh_acp.py"
        legacy = home / "ssh_acp.py"
        updated_wrapper = older / ("b" * 40) / "Host" / "ssh_acp.py"
        first = ("ssh-ed25519", "A" * 52)
        second = ("ssh-ed25519", "B" * 52)
        unrelated = 'restrict,command="/bin/echo okay" ssh-ed25519 CCC unrelated\r\n'

        def command(wrapper, flags, agent, key):
            argv = ["/usr/bin/python3", "-B", str(wrapper), "--workspace", "/work", *flags, "--", *agent]
            return f'from="192.0.2.1",restrict,command="{shlex.join(argv)}" {" ".join(key)} keep\r\n'

        source = (command(legacy, [], ["/bin/hermes-acp"], first)
                  + command(prior, ["--agent-profile-state", "/store/profile"],
                            [str(hermes), "-p", "agent", "acp"], second) + unrelated)
        with patch.object(rollout, "verify") as verify:
            updated, count, profiles = rollout.key_edits(source, updated_wrapper, {older}, legacy, policy, hermes)
            rerun, _, _ = rollout.key_edits(updated, updated_wrapper, {older}, legacy, policy, hermes)
        self.assertEqual(count, 2)
        self.assertEqual(profiles, {"default", "agent"})
        self.assertEqual(updated, rerun)
        self.assertEqual(updated.splitlines(keepends=True)[2], unrelated)
        self.assertTrue(all(row.startswith('from="192.0.2.1",restrict,command=') for row in updated.splitlines()[:2]))
        for key, profile in [(first, home), (second, home / "profiles" / "agent")]:
            _, _, prefix, index, _ = key_command(updated, key)
            self.assertEqual(prefix[index], str(updated_wrapper))
            self.assertEqual(prefix[-6:], policy.options(profile, hermes))
        self.assertIn("--agent-profile-state /store/profile", updated)
        self.assertEqual(verify.call_count, 4)
