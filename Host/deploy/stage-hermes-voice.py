#!/usr/bin/env python3
"""Stage the pinned Hermes voice transport for one existing SSH pairing."""

import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ssh_pairing_files import Edit, key_command, read_owned, require
from update_ssh_release import find_key, stage


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--authorized-keys", type=Path, default=Path.home() / ".ssh" / "authorized_keys")
    parser.add_argument("--fingerprint", required=True)
    parser.add_argument("--releases-dir", type=Path, required=True)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--hermes-source", type=Path, required=True)
    parser.add_argument("--hermes-python", type=Path, required=True)
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
        keys, _ = read_owned(args.authorized_keys)
        require(keys, "The paired authorized_keys file does not exist.")
        keys = keys.decode()
        _, _, prefix, _, _ = key_command(keys, find_key(keys, args.fingerprint))
        require("--hermes-screen" in prefix, "The pairing needs an existing Hermes profile.")
        profile = Path(prefix[prefix.index("--hermes-screen") + 1])
        require(profile.is_absolute() and profile.is_dir(), "The paired Hermes profile does not exist.")

        private_dir(args.state_dir)
        talk = stage_transport(args.state_dir)
        release = args.state_dir / args.revision
        private_dir(release)
        config = release / (args.fingerprint.removeprefix("SHA256:").replace("/", "_") + ".json")
        payload = {"gateway": {name: str(path) for name, path in {
            "home": profile, "source": args.hermes_source, "python": args.hermes_python,
            "talk": talk, "auth": args.codex_auth,
        }.items()}}
        content = (json.dumps(payload, sort_keys=True) + "\n").encode()
        previous, mode = read_owned(config)
        require(mode == 0o600 and previous in (None, content), "The revision already has a different pairing config.")
        Edit(config, previous, content, 0o600).apply()
        stage(args.releases_dir, args.revision)
        print(config)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Hermes voice staging failed ({type(error).__name__}).\n")


if __name__ == "__main__":
    main()
