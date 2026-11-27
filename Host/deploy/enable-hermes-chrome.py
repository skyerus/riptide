#!/usr/bin/env python3
"""Roll out the Chrome route to this host's current and future Hermes pairings."""

import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

HOST = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST))

from hermes_chrome_profile import CHROME, SHARED_BROWSER, ChromePolicy, PROFILE, absolute_path, owned_directory, profile_edits
from ssh_pairing_files import Edit, key_command, lock_keys, read_owned, require
from update_ssh_release import retire_safari, stage, verify


def profile_for(agent, hermes):
    if agent == [str(hermes.with_name("hermes-acp"))] or agent == [str(hermes), "acp"]:
        return "default"
    if (len(agent) == 4 and agent[0] == str(hermes) and agent[1] in ("-p", "--profile")
            and PROFILE.fullmatch(agent[2]) and agent[3] == "acp"):
        return agent[2]


def drop_options(prefix, options):
    for flag in ("--hermes-screen", "--hermes-browser-mcp"):
        if flag in prefix:
            position = prefix.index(flag)
            replacement = options.index(flag)
            require(prefix.count(flag) == 1 and len(prefix) >= position + 3,
                    "The paired key has invalid Chrome options.")
            if flag == "--hermes-screen":
                require(Path(prefix[position + 1]).resolve() == Path(options[replacement + 1]).resolve(),
                        "The paired key targets a different Hermes screen.")
            del prefix[position:position + 3]


def key_edits(source, wrapper, allowed_release_roots, legacy_wrapper, policy, hermes):
    records = set(re.findall(r"(?:^|[ \t])(ssh-ed25519) ([A-Za-z0-9+/=]+)(?=[ \t\r\n]|$)", source, re.M))
    replacements = []
    profiles = set()
    for key in records:
        try:
            start, end, prefix, script, agent = key_command(source, key)
        except ValueError:
            # Ignore ordinary SSH keys. Fail closed if a Hermes ACP entry cannot be migrated.
            matched = [line for line in source.splitlines() if re.search(rf"\s{re.escape(' '.join(key))}(?:\s|$)", line)]
            if any("ssh_acp.py" in line and str(hermes) in line for line in matched if not line.lstrip().startswith("#")):
                raise
            continue
        retire_safari(prefix, agent)
        profile = profile_for(agent, hermes)
        if profile is None:
            continue
        prior = Path(prefix[script])
        require(prior == legacy_wrapper or (prior.parent.parent.parent in allowed_release_roots
                and prior.parent.name == "Host" and re.fullmatch(r"[0-9a-f]{40}", prior.parent.parent.name)),
                "A Hermes pairing uses an unrecognized host release.")
        options = policy.options(policy.profile_home(profile), hermes)
        drop_options(prefix, options)
        prefix[script] = str(wrapper)
        argv = [*prefix, *options, "--", *agent]
        verify(argv)
        quoted = shlex.join(argv).replace('"', r'\"')
        replacements.append((start, end, f'command="{quoted}"'))
        profiles.add(profile)
    for start, end, text in sorted(replacements, reverse=True):
        source = source[:start] + text + source[end:]
    return source, len(replacements), profiles


def activate(args):
    require(re.fullmatch(r"[0-9a-f]{40}", args.revision), "Use the full merged revision.")
    chrome = {key: str(getattr(args, key)) for key in ("home", "python", "source")}
    policy = ChromePolicy.from_config(chrome)
    owned_directory(args.releases)
    manifest = absolute_path(str(args.manifest))
    require(os.access(CHROME, os.X_OK), "Install Chrome Stable and the Hermes computer-use driver first.")
    raw, manifest_mode = read_owned(manifest)
    require(raw is not None, "The Hermes pairing manifest does not exist.")
    config = json.loads(raw)
    hermes = absolute_path(config["hermes"])
    keys = absolute_path(config["authorizedKeys"])
    require(os.access(hermes, os.X_OK), "The configured Hermes launcher is unavailable.")
    profile_names = {"default", *config["targets"]}
    profiles = policy.home / "profiles"
    if profiles.is_dir():
        profile_names.update(path.name for path in profiles.iterdir() if PROFILE.fullmatch(path.name)
                             and (path / "config.yaml").is_file())

    wrapper = stage(args.releases, args.revision)
    skill = wrapper.parent / "hermes-browser-handoff" / "SKILL.md"
    previous_roots = {args.releases, *args.previous_releases}
    with lock_keys(keys):
        source, mode = read_owned(keys)
        require(source is not None, "The SSH authorized keys file does not exist.")
        updated, count, paired = key_edits(source.decode(), wrapper, previous_roots, args.legacy_wrapper, policy, hermes)
        require(count > 0, "No existing restricted Hermes pairings were found.")
        profile_names.update(paired)
        edits = []
        for profile in sorted(profile_names):
            edits.extend(profile_edits(policy.profile_home(profile), skill))
        if config.get("chrome") != chrome:
            config["chrome"] = chrome
            edits.append(Edit(manifest, raw, (json.dumps(config, indent=2) + "\n").encode(), manifest_mode))
        edits.append(Edit(keys, source, updated.encode(), mode))
        if args.share_with_pairable_agents:
            path = policy.home / SHARED_BROWSER
            original, sharing_mode = read_owned(path)
            require(original is not None, "Configure the existing desktop owner and members before enabling sharing.")
            sharing = json.loads(original)
            require(isinstance(sharing, dict) and sharing.get("pairing_manifest", str(manifest)) == str(manifest),
                    "The shared Chrome policy points to a different pairing manifest.")
            sharing["pairing_manifest"] = str(manifest)
            edits.append(Edit(path, original, (json.dumps(sharing, indent=2) + "\n").encode(), sharing_mode))
        changes = [edit for edit in edits if edit.before != edit.after]
        if changes:
            backup = Path(tempfile.mkdtemp(prefix="chrome-rollout-", dir=args.releases.parent))
            for edit in changes:
                if edit.before is not None:
                    target = backup / edit.path.relative_to("/")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    Edit(target, None, edit.before, 0o600).apply()
            with ExitStack() as rollback:
                for edit in changes:
                    edit.apply(rollback)
                if args.reload_gateway:
                    subprocess.run(["systemctl", "reload", "hermes-gateway.service"], check=True, timeout=15)
                rollback.pop_all()
            print(f"Rollback copies: {backup}")
    print(f"Chrome configured for {len(profile_names)} profiles and {count} restricted SSH pairings. "
          "New approved pairings inherit it.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ("manifest", "home", "python", "source", "releases"):
        parser.add_argument(f"--{key}", type=Path, required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--previous-releases", type=Path, action="append", default=[])
    parser.add_argument("--legacy-wrapper", type=Path)
    parser.add_argument("--reload-gateway", action="store_true")
    parser.add_argument("--share-with-pairable-agents", action="store_true",
                        help="Trust every current and future Chrome-enabled target in this pairing manifest.")
    args = parser.parse_args()
    try:
        for path in [args.releases, *args.previous_releases, args.legacy_wrapper]:
            if path is not None:
                absolute_path(str(path))
        activate(args)
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Hermes Chrome deployment failed. {error}\n")


if __name__ == "__main__":
    main()
