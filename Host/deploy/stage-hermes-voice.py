#!/usr/bin/env python3
"""Stage Hermes Talk and optionally enable it for all restricted Hermes SSH pairings."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from hermes_chrome_profile import owned_directory
from ssh_pairing_files import Edit, hermes_commands, key_command, lock_keys, read_owned, require
from update_ssh_release import find_key, stage, verify


TALK_REPOSITORY = "https://github.com/TheSmokeDev/hermes-talk.git"
TALK_REVISION = "55ae7b29082faf5aaebac7cb7d692c3c2f8ade4f"
TALK_FILES = ("LICENSE", "talk_auth.py", "talk_realtime.py", "talk_live_config.py",
              "talk_live_protocol.py", "talk_live_transport.py", "talk_live_realtime.py")
HERMES_REVISION = "8fc0374447313e276f6b9a2764bfc750190c966a"


def git(*args):
    return subprocess.run(["git", *args], check=True, stdout=subprocess.PIPE, timeout=45).stdout


def private_dir(path):
    path.mkdir(mode=0o700, exist_ok=True)
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700,
            "Use a mode-0700 directory owned by the deployment account.")


def stage_transport(state):
    destination = state / TALK_REVISION
    # Validate the source against the exact Git object, including on re-runs.
    with tempfile.TemporaryDirectory(prefix=".talk-stage-", dir=state) as directory:
        scratch = Path(directory)
        checkout = scratch / "upstream"
        checkout.mkdir()
        git("-C", str(checkout), "init", "-q")
        git("-C", str(checkout), "fetch", "-q", "--no-tags", "--depth=1", TALK_REPOSITORY, TALK_REVISION)
        commit = git("-C", str(checkout), "rev-parse", "FETCH_HEAD").decode().strip()
        require(commit == TALK_REVISION, "The upstream voice revision does not match the pin.")
        payload = {name: git("-C", str(checkout), "show", f"{commit}:{name}") for name in TALK_FILES}
        if not destination.exists():
            new = scratch / "release"
            new.mkdir(mode=0o700)
            for name, data in payload.items():
                (new / name).write_bytes(data)
            new.rename(destination)
        private_dir(destination)
        require(all(read_owned(destination / name)[0] == data for name, data in payload.items()),
                "The staged Talk dependency differs from its pinned source.")
    return destination


def enable_pairings(keys, hermes, wrapper, config):
    original, mode = read_owned(keys)
    require(original, "The paired authorized_keys file does not exist.")
    source = original.decode()
    replacements = []
    for start, end, prefix, script, agent, profile in hermes_commands(source, hermes):
        prefix[script] = str(wrapper)
        if "--hermes-talk-config" in prefix:
            require(prefix.count("--hermes-talk-config") == 1, "A pairing has multiple voice configurations.")
            prefix[prefix.index("--hermes-talk-config") + 1] = str(config)
        else:
            prefix.extend(["--hermes-talk-config", str(config)])
        argv = [*prefix, "--", *agent]
        try:
            verify(argv, verify_talk=True)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            raise ValueError(f"Voice readiness check failed for Hermes profile {profile}.") from error
        quoted = shlex.join(argv).replace('"', r'\"')
        replacements.append((start, end, f'command="{quoted}"'))
    require(replacements, "No existing restricted pairings match the configured Hermes launcher.")
    for start, end, command in sorted(replacements, reverse=True):
        source = source[:start] + command + source[end:]
    updated = source.encode()
    with lock_keys(keys):
        require(read_owned(keys) == (original, mode), "The SSH pairings changed during verification. Retry.")
        if updated != original:
            digest = hashlib.sha256(original).hexdigest()
            backup = config.parent / f"authorized_keys.{digest}.before"
            previous, backup_mode = read_owned(backup)
            require(backup_mode == 0o600 and previous in (None, original), "Unexpected pairing backup contents.")
            Edit(backup, previous, original, 0o600).apply()
            Edit(keys, original, updated, mode).apply()
    return len(replacements)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--authorized-keys", type=Path, default=Path.home() / ".ssh" / "authorized_keys")
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--fingerprint")
    selection.add_argument("--all-pairings", action="store_true")
    parser.add_argument("--releases-dir", type=Path, required=True)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--hermes-source", type=Path, required=True)
    parser.add_argument("--hermes-python", type=Path, required=True)
    parser.add_argument("--hermes", type=Path, help="Installed Hermes launcher for --all-pairings.")
    parser.add_argument("--hermes-home", type=Path, help="Root Hermes home for --all-pairings.")
    parser.add_argument("--codex-auth", type=Path, required=True)
    args = parser.parse_args()
    try:
        require(all(path.is_absolute() for path in (args.authorized_keys, args.releases_dir, args.state_dir,
                    args.hermes_source, args.hermes_python, args.codex_auth)), "Use absolute deployment paths.")
        require(re.fullmatch(r"[a-f0-9]{40}", args.revision), "Use the full Riptide Git revision.")
        require(git("-C", str(args.hermes_source), "rev-parse", "HEAD").decode().strip() == HERMES_REVISION,
                "Verify the canonical voice calls against this Hermes revision before activating.")
        require(os.access(args.hermes_python, os.X_OK), "Use the existing Hermes managed Python executable.")
        data, auth_mode = read_owned(args.codex_auth)
        require(data and auth_mode == 0o600 and json.loads(data).get("auth_mode") == "chatgpt",
                "Use the existing mode-0600 Codex subscription credential file.")
        if args.all_pairings:
            require(args.hermes is not None and args.hermes.is_absolute() and os.access(args.hermes, os.X_OK)
                    and args.hermes_home is not None and args.hermes_home.is_absolute(),
                    "--all-pairings requires an absolute Hermes launcher and home.")
            owned_directory(args.hermes_home)
            owned_directory(args.releases_dir)
            home = args.hermes_home
            config_name = "shared-gateway.json"
        else:
            keys, _ = read_owned(args.authorized_keys)
            require(keys, "The paired authorized_keys file does not exist.")
            keys = keys.decode()
            _, _, prefix, _, _ = key_command(keys, find_key(keys, args.fingerprint))
            require("--hermes-screen" in prefix, "The pairing needs an existing Hermes profile.")
            home = Path(prefix[prefix.index("--hermes-screen") + 1])
            require(home.is_absolute() and home.is_dir(), "The paired Hermes profile does not exist.")
            config_name = args.fingerprint.removeprefix("SHA256:").replace("/", "_") + ".json"

        private_dir(args.state_dir)
        talk = stage_transport(args.state_dir)
        release = args.state_dir / args.revision
        private_dir(release)
        config = release / config_name
        payload = {"gateway": {name: str(path) for name, path in {
            "home": home, "source": args.hermes_source, "python": args.hermes_python,
            "talk": talk, "auth": args.codex_auth,
        }.items()}}
        if args.all_pairings:
            payload["gateway"]["hermes"] = str(args.hermes)
        content = (json.dumps(payload, sort_keys=True) + "\n").encode()
        previous, mode = read_owned(config)
        require(mode == 0o600 and previous in (None, content), "The revision already has a different pairing config.")
        Edit(config, previous, content, 0o600).apply()
        wrapper = stage(args.releases_dir, args.revision)
        if args.all_pairings:
            count = enable_pairings(args.authorized_keys, args.hermes, wrapper, config)
            print(f"Hermes Talk enabled for {count} restricted Hermes SSH pairings.")
        print(config)
    except ValueError as error:
        parser.exit(1, f"Hermes voice setup failed. {error}\n")
    except (OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Hermes voice setup failed ({type(error).__name__}).\n")


if __name__ == "__main__":
    main()
