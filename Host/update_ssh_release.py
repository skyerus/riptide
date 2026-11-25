#!/usr/bin/env python3
"""Switch one existing restricted Riptide SSH pairing to a versioned host payload."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import tempfile

from install_safari import Edit, HOST, PAYLOAD, key_command, read_owned, require


def find_key(source, fingerprint):
    keys = set(re.findall(r"(?:^|[ \t])(ssh-ed25519 [A-Za-z0-9+/=]+)(?=[ \t\r\n]|$)", source, re.M))
    matches = []
    for key in keys:
        result = subprocess.run(["ssh-keygen", "-lf", "-"], input=key + "\n", text=True, capture_output=True)
        if result.returncode == 0 and result.stdout.split()[1] == fingerprint:
            matches.append(tuple(key.split()))
    require(len(matches) == 1, "Expected exactly one Ed25519 key matching the supplied fingerprint.")
    return matches[0]


def stage(releases, revision):
    destination = releases / revision / "Host"
    payload = {name: (HOST / name).read_bytes() for name in PAYLOAD}
    if not destination.exists():
        with tempfile.TemporaryDirectory(prefix=".riptide-stage-", dir=releases) as directory:
            staging = Path(directory) / revision / "Host"
            staging.mkdir(parents=True)
            for name, data in payload.items():
                compile(data, name, "exec")
                (staging / name).write_bytes(data)
            staging.parent.rename(destination.parent)
    require(all(read_owned(destination / name)[0] == data for name, data in payload.items()),
            "The versioned host payload does not match this release.")
    return destination / "ssh_acp.py"


def verify(argv):
    def run(route, request):
        result = subprocess.run(argv, env={**os.environ, "SSH_ORIGINAL_COMMAND": route},
                                input=request, text=True, capture_output=True, timeout=8)
        require(result.returncode == 0, f"The staged {route} command failed.")
        return result.stdout

    if "--safari" in argv:
        state = json.loads(run("riptide-safari", '{"operation":"state","body":{}}\n'))
        require(state.get("status") == 200, "The existing Safari SSH route did not respond.")
    require(run("riptide-hermes-screen", "") == "", "The Hermes screen command did not close cleanly.")


def update(keys, fingerprint, releases, previous, revision):
    directory = releases.lstat()
    require(stat.S_ISDIR(directory.st_mode) and directory.st_uid == os.getuid() and not directory.st_mode & 0o022,
            "Use an existing release directory controlled by the deployment account.")
    # Keep concurrent upgrades for this release directory from racing each other.
    with (releases / ".update-ssh.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        original, mode = read_owned(keys)
        require(original is not None, "The paired authorized_keys file does not exist.")
        source = original.decode()
        start, end, prefix, script, agent = key_command(source, find_key(source, fingerprint))
        require("--hermes-screen" in prefix, "The paired key does not have a Hermes screen route.")
        old = releases / previous / "Host" / "ssh_acp.py"
        new = releases / revision / "Host" / "ssh_acp.py"
        require(Path(prefix[script]) in (old, new), "The pairing points to an unexpected SSH release.")
        already_active = Path(prefix[script]) == new
        prefix[script] = str(stage(releases, revision))
        argv = [*prefix, "--", *agent]
        verify(argv)
        if not already_active:
            command = shlex.join(argv).replace('"', r'\"')
            after = (source[:start] + f'command="{command}"' + source[end:]).encode()
            Edit(keys, original, after, mode).apply()
    print(f"Verified and activated SSH release {revision} for the selected pairing.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--authorized-keys", type=Path, default=Path.home() / ".ssh" / "authorized_keys")
    parser.add_argument("--fingerprint", required=True)
    parser.add_argument("--releases-dir", type=Path, required=True)
    parser.add_argument("--previous", required=True)
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()
    if not all(re.fullmatch(r"[0-9a-f]{40}", value) for value in (args.previous, args.revision)):
        parser.error("Pass full Git revisions for --previous and --revision.")
    if not args.releases_dir.is_absolute():
        parser.error("Pass an absolute --releases-dir.")
    try:
        update(args.authorized_keys, args.fingerprint, args.releases_dir, args.previous, args.revision)
    except subprocess.TimeoutExpired:
        parser.exit(1, "The staged SSH command timed out during verification.\n")
    except (OSError, ValueError) as error:
        parser.exit(1, f"SSH release update failed. {error}\n")


if __name__ == "__main__":
    main()
