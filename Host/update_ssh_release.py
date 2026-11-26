#!/usr/bin/env python3
"""Switch one existing restricted Riptide SSH pairing to a versioned host payload."""

import argparse
import asyncio
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import tempfile

from agent_profile import RENAME, read_name
from ssh_pairing_files import Edit, key_command, read_owned, require


HOST = Path(__file__).resolve().parent
PAYLOAD = ("ssh_acp.py", "hermes_screen.py", "hermes_groups.py", "hermes_browser_mcp.py", "codex_dictation.py",
           "attention_relay.py", "hermes_attention.py", "hermes_pairing.py", "agent_pairing_mcp.py",
           "agent_profile.py", "mcp_stdio.py", "ssh_pairing_files.py")


def retire_safari(prefix, agent):
    # Migrate existing forced commands without touching other SSH options or env assignments.
    for flag, count in (("--safari", 2), ("--safari-mcp-python", 1)):
        if flag in prefix:
            index = prefix.index(flag)
            require(prefix.count(flag) == 1 and len(prefix) > index + count,
                    "Invalid legacy Safari options in the pairing.")
            del prefix[index:index + count + 1]
    if Path(agent[0]).name == "env" and any(arg.startswith("RIPTIDE_SAFARI_CODEX_") for arg in agent[1:]):
        index = 1
        while index < len(agent) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", agent[index]):
            if agent[index].startswith(("RIPTIDE_SAFARI_CODEX_PYTHON=", "RIPTIDE_SAFARI_CODEX_STATE_DIR=")):
                del agent[index]
            else:
                index += 1
        if len(agent) > 1 and index == 1 and Path(agent[1]).is_absolute():
            del agent[0]


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
                                input=request, text=True, capture_output=True,
                                timeout=40 if route == "riptide-hermes-groups" else 8)
        require(result.returncode == 0, f"The staged {route} command failed.")
        return result.stdout

    if "--hermes-screen" in argv:
        require(run("riptide-hermes-screen", "") == "", "The Hermes screen command did not close cleanly.")
    if "--hermes-browser-mcp" in argv:
        start = argv.index("--hermes-browser-mcp")
        python, source = argv[start + 1:start + 3]
        profile = argv[argv.index("--hermes-screen") + 1]
        wrapper = next(Path(arg) for arg in argv if Path(arg).name == "ssh_acp.py")
        frame = {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}
        result = subprocess.run([python, "-B", str(wrapper.with_name("hermes_browser_mcp.py")),
                                 "--hermes-source", source, "--profile", profile],
                                input=json.dumps(frame) + "\n", text=True, capture_output=True, timeout=12)
        require(result.returncode == 0, "The staged Chrome connector could not start.")
        tools = json.loads(result.stdout).get("result", {}).get("tools", [])
        require({"computer_use", "chrome_handoff"} <= {tool.get("name") for tool in tools},
                "The staged Chrome connector is missing required tools.")
    if "--pairing-config" in argv:
        prefix = argv[:argv.index("--")]
        wrapper = next(Path(arg) for arg in prefix if Path(arg).name == "ssh_acp.py")
        pairing = prefix[prefix.index("--pairing-config") + 1]
        frames = (
            {"id": 1, "method": "initialize", "params": {
                "protocolVersion": "2025-11-25", "capabilities": {},
                "clientInfo": {"name": "riptide-release-verifier", "version": "1"},
            }},
            {"method": "notifications/initialized"},
            {"id": 2, "method": "tools/call", "params": {"name": "list_pairable_agents", "arguments": {}}},
        )
        result = subprocess.run(
            [prefix[0], "-BE", str(wrapper.with_name("agent_pairing_mcp.py")), "--config", pairing],
            input="".join(json.dumps({"jsonrpc": "2.0", **frame}) + "\n" for frame in frames),
            text=True, capture_output=True, timeout=8,
        )
        require(result.returncode == 0, "The staged pairing connector could not start.")
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        reply = next((frame.get("result", {}) for frame in responses if frame.get("id") == 2), {})
        require(reply.get("isError") is False, "The staged pairing connector could not read its manifest.")
    if "--agent-profile-state" in argv:
        prefix = argv[:argv.index("--")]
        wrapper = next(Path(arg) for arg in prefix if Path(arg).name == "ssh_acp.py")
        state = Path(prefix[prefix.index("--agent-profile-state") + 1])
        read_name(state)
        frame = {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}
        result = subprocess.run([prefix[0], "-BE", str(wrapper.with_name("agent_profile.py")), "--state", str(state)],
                                input=json.dumps(frame) + "\n", text=True, capture_output=True, timeout=8)
        require(result.returncode == 0, "The staged agent profile tool could not start.")
        tools = json.loads(result.stdout).get("result", {}).get("tools", [])
        require(any(tool.get("name") == RENAME for tool in tools), "The staged agent profile tool is missing.")
    if "--hermes-groups" in argv:
        probe = {"jsonrpc": "2.0", "id": "verify-groups", "method": "groups.capabilities", "params": {}}
        groups = json.loads(run("riptide-hermes-groups", json.dumps(probe) + "\n"))
        require(groups.get("id") == probe["id"] and groups.get("result", {}).get("driver") is True,
                "The selected Hermes gateway is not running a group chat driver.")


def update(keys, fingerprint, releases, previous, revision, attention_socket=None, pairing_config=None,
           enable_hermes_groups=False, agent_profile_state=None, browser_mcp=None, previous_releases=None, hermes_screen=None):
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
        old = (previous_releases or releases) / previous / "Host" / "ssh_acp.py"
        new = releases / revision / "Host" / "ssh_acp.py"
        require(Path(prefix[script]) in (old, new), "The pairing points to an unexpected SSH release.")
        retire_safari(prefix, agent)
        prefix[script] = str(stage(releases, revision))
        if attention_socket is not None:
            from hermes_attention import exchange
            require(attention_socket.is_absolute(), "Use an absolute notification socket path.")
            reply = asyncio.run(exchange(attention_socket, {"operation": "health"}))
            require(reply == {"ok": True}, "The private notification relay did not respond.")
            if "--attention-socket" in prefix:
                prefix[prefix.index("--attention-socket") + 1] = str(attention_socket)
            else:
                prefix.extend(["--attention-socket", str(attention_socket)])
        if pairing_config is not None:
            require(pairing_config.is_absolute() and read_owned(pairing_config)[0] is not None,
                    "Use an existing absolute path to an owner-controlled pairing manifest.")
            if "--pairing-config" in prefix:
                prefix[prefix.index("--pairing-config") + 1] = str(pairing_config)
            else:
                prefix.extend(["--pairing-config", str(pairing_config)])
        if agent_profile_state is not None:
            if "--agent-profile-state" in prefix:
                prefix[prefix.index("--agent-profile-state") + 1] = str(agent_profile_state)
            else:
                prefix.extend(["--agent-profile-state", str(agent_profile_state)])
        if hermes_screen is not None:
            home, hermes = hermes_screen
            require(home.is_absolute() and home.is_dir() and hermes.is_absolute() and os.access(hermes, os.X_OK),
                    "Use the paired profile’s absolute Hermes home and executable.")
            screen = [str(home.resolve()), str(hermes)]
            if "--hermes-screen" in prefix:
                option = prefix.index("--hermes-screen")
                require(prefix[option + 1:option + 3] == screen, "The pairing already uses another Hermes screen.")
            else:
                prefix.extend(["--hermes-screen", *screen])
        if enable_hermes_groups and "--hermes-groups" not in prefix:
            require("--hermes-screen" in prefix, "The paired key has no Hermes screen profile for groups.")
            screen = prefix.index("--hermes-screen")
            prefix.extend(["--hermes-groups", *prefix[screen + 1:screen + 3]])
        if browser_mcp is not None:
            browser_python, browser_source = browser_mcp
            require("--hermes-screen" in prefix and browser_python.is_absolute() and os.access(browser_python, os.X_OK)
                    and browser_source.is_absolute() and browser_source.is_dir(),
                    "The Chrome connector needs the paired screen and absolute Hermes Python and source paths.")
            if "--hermes-browser-mcp" in prefix:
                option = prefix.index("--hermes-browser-mcp")
                prefix[option + 1:option + 3] = [str(browser_python), str(browser_source)]
            else:
                prefix.extend(["--hermes-browser-mcp", str(browser_python), str(browser_source)])
        argv = [*prefix, "--", *agent]
        verify(argv)
        command = shlex.join(argv).replace('"', r'\"')
        after = (source[:start] + f'command="{command}"' + source[end:]).encode()
        if after != original:
            Edit(keys, original, after, mode).apply()
    print(f"Verified and activated SSH release {revision} for the selected pairing.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--authorized-keys", type=Path, default=Path.home() / ".ssh" / "authorized_keys")
    parser.add_argument("--fingerprint", required=True)
    parser.add_argument("--releases-dir", type=Path, required=True)
    parser.add_argument("--previous", required=True)
    parser.add_argument("--previous-releases-dir", type=Path)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--attention-socket", type=Path)
    parser.add_argument("--pairing-config", type=Path)
    parser.add_argument("--agent-profile-state", type=Path,
                        help="Absolute per-agent display name file inside a private directory.")
    parser.add_argument("--hermes-screen", type=Path, nargs=2, metavar=("PROFILE_HOME", "HERMES"),
                        help="Add Bot Screen for this trusted pairing’s own Hermes profile.")
    parser.add_argument("--hermes-browser-mcp", type=Path, nargs=2, metavar=("PYTHON", "HERMES_SOURCE"),
                        help="Give Codex access to this pairing's existing Hermes Bot Screen Chrome.")
    parser.add_argument("--enable-hermes-groups", action="store_true",
                        help="Let this key access group chats on its paired Hermes gateway.")
    args = parser.parse_args()
    if not all(re.fullmatch(r"[0-9a-f]{40}", value) for value in (args.previous, args.revision)):
        parser.error("Pass full Git revisions for --previous and --revision.")
    if not args.releases_dir.is_absolute() or (args.previous_releases_dir and not args.previous_releases_dir.is_absolute()):
        parser.error("Use absolute release directories.")
    try:
        update(args.authorized_keys, args.fingerprint, args.releases_dir, args.previous, args.revision,
               args.attention_socket, args.pairing_config, args.enable_hermes_groups, args.agent_profile_state,
               args.hermes_browser_mcp, args.previous_releases_dir, args.hermes_screen)
    except subprocess.TimeoutExpired:
        parser.exit(1, "The staged SSH command timed out during verification.\n")
    except (OSError, ValueError) as error:
        parser.exit(1, f"SSH release update failed. {error}\n")


if __name__ == "__main__":
    main()
