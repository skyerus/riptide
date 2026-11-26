#!/usr/bin/env python3
"""Enable the private push relay for existing and future Hermes SSH pairings."""

import argparse
import asyncio
import os
from pathlib import Path
import re
import shlex
import sys

HOST = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST))

from hermes_attention import exchange
from hermes_chrome_profile import owned_directory
from ssh_pairing_files import Edit, hermes_commands, lock_keys, read_owned, require
from update_ssh_release import stage


def key_edits(source, hermes, wrapper, socket):
    replacements = []
    scopes = set()
    for start, end, prefix, script, agent, profile in hermes_commands(source, hermes):
        if "--attention-profile" in prefix:
            index = prefix.index("--attention-profile")
            require(prefix[index + 1] == profile, "A pairing already names another notification profile.")
            del prefix[index:index + 2]
        if "--attention-socket" in prefix:
            index = prefix.index("--attention-socket")
            require(prefix[index + 1] == str(socket), "A pairing already uses another notification relay.")
            del prefix[index:index + 2]
        prefix[script] = str(wrapper)
        workspace = prefix[prefix.index("--workspace") + 1]
        scopes.add((profile, workspace))
        argv = [*prefix, "--attention-socket", str(socket), "--attention-profile", profile, "--", *agent]
        quoted = shlex.join(argv).replace('"', r'\"')
        replacements.append((start, end, f'command="{quoted}"'))
    for start, end, text in sorted(replacements, reverse=True):
        source = source[:start] + text + source[end:]
    return source, len(replacements), scopes


async def verify(socket, scopes):
    for profile, workspace in sorted(scopes):
        reply = await exchange(socket, {"operation": "health", "scope": {"profile": profile, "workspace": workspace}})
        require(reply == {"ok": True}, "The notification relay did not accept a paired Hermes scope.")


def activate(args):
    require(re.fullmatch(r"[0-9a-f]{40}", args.revision), "Use the full release revision.")
    owned_directory(args.releases)
    require(os.access(args.hermes, os.X_OK), "The configured Hermes launcher is unavailable.")
    wrapper = stage(args.releases, args.revision)
    with lock_keys(args.authorized_keys):
        original, mode = read_owned(args.authorized_keys)
        require(original is not None, "The SSH authorized keys file does not exist.")
        updated, count, scopes = key_edits(original.decode(), args.hermes, wrapper, args.socket)
        require(count, "No existing restricted Hermes pairings were found.")
        asyncio.run(verify(args.socket, scopes))
        Edit(args.authorized_keys, original, updated.encode(), mode).apply()
    print(f"Push enabled for {count} restricted Hermes pairings across {len(scopes)} profile and workspace scopes.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("authorized-keys", "hermes", "releases", "socket"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()
    try:
        require(all(path.is_absolute() for path in (args.authorized_keys, args.hermes, args.releases, args.socket)),
                "Use absolute host paths.")
        activate(args)
    except (OSError, ValueError, IndexError) as error:
        parser.exit(1, f"Hermes notification deployment failed. {error}\n")


if __name__ == "__main__":
    main()
