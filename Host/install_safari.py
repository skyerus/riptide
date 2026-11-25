#!/usr/bin/env python3
"""Enable the Riptide Safari relay for one existing OpenSSH pairing."""

import argparse
from contextlib import ExitStack
from dataclasses import dataclass
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
from time import monotonic, sleep

from safari_bridge import RelayError, browser_call


HOST = Path(__file__).resolve().parent
PAYLOAD = ("ssh_acp.py", "hermes_screen.py", "hermes_mobile.py", "codex_dictation.py",
           "safari_bridge.py", "safari_mcp.py", "safari_codex.py")
REQUIREMENTS = ("safari-installer-requirements.txt", "safari-requirements.txt")
MARKER = "# Managed by the Riptide Safari installer"
PYTHON_ENV = "RIPTIDE_SAFARI_CODEX_PYTHON"
STATE_ENV = "RIPTIDE_SAFARI_CODEX_STATE_DIR"
# OpenSSH permits double-quoted option values with backslash-escaped double quotes.
OPTION = re.compile(r'[A-Za-z0-9-]+(?:="(?:\\"|\\(?!")|[^"\\\r\n])*")?')
# Only rewrite a fixed argv command. Shell expansions and compound commands keep their own semantics.
SHELL_PIECE = re.compile(r'''[ \t\w./@%+=:,-]+|'[^'\r\n]*'|"[^"\\$`\r\n]*"''')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_owned(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None, 0o600
    mode = stat.S_IMODE(info.st_mode)
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and not mode & 0o022,
            f"Use a regular, owner-controlled file at {path}.")
    return path.read_bytes(), mode


def private_directory(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o077,
            f"Use a directory owned by this user with mode 0700 at {path}.")


@dataclass
class Edit:
    path: Path
    before: bytes | None
    after: bytes
    mode: int

    @classmethod
    def prepare(cls, path, after, mode=0o600):
        before, current_mode = read_owned(path)
        return cls(path, before, after, current_mode if before is not None else mode)

    def replace(self, expected, content):
        require(read_owned(self.path)[0] == expected, f"{self.path} changed during installation. Retry.")
        if content is None:
            self.path.unlink()
            return
        fd, name = tempfile.mkstemp(dir=self.path.parent, prefix=".riptide-safari-")
        try:
            with os.fdopen(fd, "wb") as stream:
                os.fchmod(stream.fileno(), self.mode)
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(name, self.path)
        finally:
            Path(name).unlink(missing_ok=True)

    def apply(self, rollback=None):
        if self.before != self.after:
            self.replace(self.before, self.after)
            if rollback is not None:
                rollback.callback(self.replace, self.after, self.before)


def key_identity(public_key):
    tokens = public_key.split()
    require(len(tokens) >= 2 and tokens[0] == "ssh-ed25519", "Paste the Riptide ssh-ed25519 public key.")
    key = tuple(tokens[:2])
    valid = subprocess.run(["ssh-keygen", "-lf", "-"], input=" ".join(key) + "\n",
                           text=True, capture_output=True)
    require(valid.returncode == 0, "The Riptide SSH public key is invalid.")
    # This ID is routing metadata, stable across reinstalls and different for every key.
    return key, hashlib.sha256(key[1].encode()).hexdigest()[:32]


def key_command(source, key):
    matches = []
    for line in re.finditer(r"^[ \t]*(.*)$", source, flags=re.MULTILINE):
        content = line.group(1)
        if content.startswith("#"):
            continue
        options = []
        end = 0
        while option := OPTION.match(content, end):
            options.append(option)
            end = option.end()
            if content[end:end + 1] != ",":
                break
            end += 1
        remainder = content[end:] if end and content[end:end + 1] in (" ", "\t") else ""
        if tuple(content.split()[:2]) == key or tuple(remainder.split()[:2]) == key:
            commands = [option for option in options if option[0].lower().startswith('command="')]
            matches.append((line, options, commands))

    require(len(matches) == 1, "The exact Riptide public key must occur once in authorized_keys.")
    line, options, commands = matches[0]
    option_names = {option[0].split("=", 1)[0].lower() for option in options}
    require(len(commands) == 1 and "restrict" in option_names
            and option_names.isdisjoint({"agent-forwarding", "port-forwarding", "pty", "user-rc", "x11-forwarding",
                                         "cert-authority"}),
            "Expected a Riptide key with a restricted ACP forced command.")
    command = commands[0]
    raw = command[0].split("=", 1)[1][1:-1].replace(r'\"', '"')
    require(sum(len(piece[0]) for piece in SHELL_PIECE.finditer(raw)) == len(raw),
            "The paired SSH command must use fixed arguments without shell expansions.")
    argv = shlex.split(raw)
    try:
        boundary = argv.index("--")
    except ValueError:
        raise ValueError("Expected a Riptide ssh_acp.py forced command followed by -- and the agent launcher.") from None
    prefix, agent = argv[:boundary], argv[boundary + 1:]
    scripts = [index for index, value in enumerate(prefix) if Path(value).name == "ssh_acp.py"]
    require(len(scripts) == 1 and 0 < scripts[0] < boundary and "--workspace" in prefix[scripts[0] + 1:]
            and all(re.fullmatch(r"-[BIu]+", flag) for flag in prefix[1:scripts[0]])
            and agent and Path(agent[0]).is_absolute()
            and Path(prefix[0]).is_absolute() and Path(prefix[scripts[0]]).is_absolute(),
            "Expected absolute Python, ssh_acp.py and agent paths in the paired key’s forced command.")
    return line.start(1) + command.start(), line.start(1) + command.end(), prefix, scripts[0], agent


def revised_command(prefix, script, agent, release, state, device, python, runtime):
    prefix = prefix.copy()
    agent = agent.copy()
    socket = str(state / "browser.sock")
    require(prefix.count("--safari") <= 1 and prefix.count("--safari-mcp-python") <= 1,
            "The paired key contains duplicate Safari flags.")
    if "--safari" in prefix:
        position = prefix.index("--safari")
        require(prefix[position + 1:position + 3] == [socket, device],
                "This pairing already uses a different Safari relay. Keep managing it manually or remove that route first.")
        del prefix[position:position + 3]
    if "--safari-mcp-python" in prefix:
        position = prefix.index("--safari-mcp-python")
        del prefix[position:position + 2]
    if len(agent) > 2 and agent[0] == "/usr/bin/env" and agent[1].startswith(PYTHON_ENV + "="):
        require(agent[2] == f"{STATE_ENV}={state}", "The paired key has different Codex Safari settings.")
        agent = agent[3:]
    require(not any(item.startswith((PYTHON_ENV + "=", STATE_ENV + "=")) for item in agent),
            "The paired key already sets Safari variables outside the installer’s launch arguments.")

    prefix[script] = str(release / "ssh_acp.py")
    prefix.extend(("--safari", socket, device))
    if runtime != "stdio":
        prefix.extend(("--safari-mcp-python", str(python)))
    if runtime == "hermes-codex":
        agent = ["/usr/bin/env", f"{PYTHON_ENV}={python}", f"{STATE_ENV}={state}", *agent]
    return [*prefix, "--", *agent]


def content_id(paths):
    digest = hashlib.sha256()
    for name in paths:
        digest.update(name.encode() + b"\0" + hashlib.sha256((HOST / name).read_bytes()).digest())
    return digest.hexdigest()[:20]


def provision_files(root):
    release = root / "releases" / content_id(PAYLOAD)
    release.mkdir(mode=0o700, parents=True, exist_ok=True)
    private_directory(release)
    for name in PAYLOAD:
        Edit.prepare(release / name, (HOST / name).read_bytes()).apply()

    dependency_id = content_id(REQUIREMENTS) + f"-{sys.version_info.major}.{sys.version_info.minor}"
    venv = root / "venvs" / dependency_id
    python = venv / "bin" / "python"
    marker = venv / ".installed"
    if not marker.is_file():
        subprocess.run([sys.executable, "-m", "venv", str(venv)], check=True)
        subprocess.run([str(python), "-m", "pip", "install", "--disable-pip-version-check",
                        "-r", str(HOST / REQUIREMENTS[0])], check=True)
        subprocess.run([str(python), "-c", "import mcp, yaml"], check=True)
        Edit.prepare(marker, b"").apply()
    require(os.access(python, os.X_OK), f"The installed virtual environment at {venv} is incomplete.")
    return release, python


def hermes_home(home, agent):
    for argument in agent[1:]:
        if argument.startswith("HERMES_HOME="):
            path = Path(argument.split("=", 1)[1])
            require(path.is_absolute(), "Pass --hermes-config for a custom Hermes profile.")
            return path
        if argument in ("--profile", "-p") or argument.startswith("--profile="):
            raise ValueError("Pass --hermes-config with the selected Hermes profile’s config.yaml.")
    return home / ".hermes"


def codex_edits(config_path, root, release, python):
    source, mode = read_owned(config_path)
    require(source is not None, f"No Hermes config at {config_path}. Use --hermes-config for a custom profile.")
    profile_id = hashlib.sha256(os.fsencode(config_path)).hexdigest()[:24]
    profile_dir = root / "codex" / profile_id
    launcher = profile_dir / "codex"
    target = profile_dir / "target"
    original, _ = read_owned(target)
    result = subprocess.run([str(python), "-B", str(HOST / "safari_install_config.py"), str(launcher),
                             original.decode() if original else ""], input=source.decode(),
                            text=True, capture_output=True)
    require(result.returncode == 0, result.stderr.strip() or "Could not inspect the Hermes configuration.")
    settings = json.loads(result.stdout)
    if settings is None:
        return []
    binary = settings["binary"]
    require(not Path(binary).is_relative_to(root), "Set model.codex_bin to the original Codex executable and retry.")
    private_directory(profile_dir)
    current_launcher, _ = read_owned(launcher)
    require(current_launcher is None or current_launcher.startswith(f"#!/bin/sh\n{MARKER}\n".encode()),
            f"The existing launcher at {launcher} is not managed by Riptide.")
    command = shlex.join([sys.executable, "-B", str(release / "safari_codex.py"), binary])
    wrapper = f'#!/bin/sh\n{MARKER}\nexec {command} "$@"\n'
    return [Edit.prepare(target, binary.encode()), Edit.prepare(launcher, wrapper.encode(), 0o700),
            Edit(config_path, source, settings["config"].encode(), mode)]


def systemctl(*args, check=True):
    return subprocess.run(["systemctl", "--user", *args], check=check, capture_output=True, text=True)


def unit_content(release, state):
    args = [sys.executable, "-B", str(release / "safari_bridge.py"), "--state-dir", str(state), "serve"]
    # A colon disables systemd environment substitution. Double percent signs escape unit specifiers.
    command = " ".join(json.dumps(arg.replace("%", "%%"), ensure_ascii=False) for arg in args)
    return (f"{MARKER}\n[Unit]\nDescription=Riptide Safari relay\n\n"
            f"[Service]\nExecStart=:{command}\nRestart=on-failure\nUMask=0077\n\n"
            "[Install]\nWantedBy=default.target\n").encode()


def wait_for_relay(state, device):
    deadline = monotonic() + 5
    while monotonic() < deadline:
        try:
            browser_call(state / "browser.sock", device, "state", {})
            for name in ("browser.sock", "agent.sock"):
                info = (state / name).lstat()
                require(stat.S_ISSOCK(info.st_mode) and info.st_uid == os.getuid()
                        and stat.S_IMODE(info.st_mode) == 0o600, "Relay sockets must be private to the agent account.")
            return
        except RelayError:
            sleep(0.1)
    raise ValueError("The Safari relay did not respond. Check the user service journal.")


def start_relay(unit, state, device, rollback):
    name = unit.path.name
    active = systemctl("is-active", "--quiet", name, check=False).returncode == 0
    enabled = systemctl("is-enabled", "--quiet", name, check=False).returncode == 0
    changed = unit.before != unit.after
    if not (changed or not active or not enabled):
        wait_for_relay(state, device)
        return

    def restore_service():
        if not active:
            systemctl("stop", name, check=False)
        if not enabled:
            systemctl("disable", name, check=False)
        if changed:
            unit.replace(unit.after, unit.before)
            systemctl("daemon-reload")
            if active:
                systemctl("restart", name)

    unit.apply()
    rollback.callback(restore_service)
    if changed:
        systemctl("daemon-reload")
    if not enabled:
        systemctl("enable", name)
    if not active:
        systemctl("start", name)
    elif changed:
        systemctl("restart", name)
    wait_for_relay(state, device)


def verify_ssh_route(argv, script):
    response = subprocess.run([sys.executable, "-B", *argv[script:]], timeout=8,
                              env={**os.environ, "SSH_ORIGINAL_COMMAND": "riptide-safari"},
                              input='{"operation":"state","body":{}}\n', text=True, capture_output=True)
    result = json.loads(response.stdout) if response.returncode == 0 else {}
    require(result.get("status") == 200,
            "The selected SSH command did not reach the Safari relay. Check its Riptide options.")


def install(args, home):
    key, device = key_identity(args.key)
    keys = args.authorized_keys.expanduser() if args.authorized_keys else home / ".ssh" / "authorized_keys"
    root = home / ".local" / "share" / "riptide-safari"
    state_root = home / ".local" / "state" / "riptide-safari"
    state = state_root / device[:16]
    name = f"riptide-safari-{device[:16]}.service"
    config_home = Path(os.environ.get("XDG_CONFIG_HOME", ""))
    if not config_home.is_absolute():
        config_home = home / ".config"
    unit_path = config_home / "systemd" / "user" / name
    require(not any(character in str(home) for character in "\r\n"), "The agent home path must fit on one line.")
    require(len(os.fsencode(state / "browser.sock")) < 108, "The home path is too long for Linux Unix sockets.")
    systemctl("show-environment")  # Validate the user manager before changing files.
    private_directory(root)

    with (root / ".install.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        original, mode = read_owned(keys)
        require(original is not None, f"No SSH authorized_keys file at {keys}. Pair Riptide over SSH first.")
        source = original.decode()
        start, end, prefix, script, agent = key_command(source, key)
        release, python = provision_files(root)
        edits = []
        runtime = args.runtime
        if runtime == "hermes":
            config = args.hermes_config or hermes_home(home, agent) / "config.yaml"
            edits = codex_edits(Path(os.path.abspath(config.expanduser())), root, release, python)
            if edits:
                runtime = "hermes-codex"
        argv = revised_command(prefix, script, agent, release, state, device, python, runtime)
        command = shlex.join(argv).replace('"', r'\"')
        key_edit = Edit(keys, original, (source[:start] + f'command="{command}"' + source[end:]).encode(), mode)
        private_directory(state_root)
        private_directory(state)
        unit_path.parent.mkdir(parents=True, exist_ok=True)
        unit = Edit.prepare(unit_path, unit_content(release, state))
        require(unit.before is None or unit.before.startswith(MARKER.encode() + b"\n"),
                f"The service file at {unit_path} is not managed by Riptide.")
        with ExitStack() as rollback:
            start_relay(unit, state, device, rollback)
            verify_ssh_route(argv, script)
            for edit in edits:
                edit.apply(rollback)
            key_edit.apply()
            rollback.pop_all()

    print(f"Riptide Safari relay is installed for this SSH pairing ({runtime}).")
    print(f"Relay service: {name}")
    if runtime == "hermes-codex":
        print("If a persistent Hermes gateway owns Codex, see Host/compat/hermes-gateway-safari.md for its setup.")
    elif runtime == "stdio":
        print("Add this stdio MCP server to your agent’s configuration:")
        print(json.dumps({"riptide_safari": {"command": str(python),
                                             "args": [str(release / "safari_mcp.py"), "--state-dir", str(state)]}},
                         indent=2))
        print("If supported, configure an MCP tool timeout of at least 90 seconds.")
    print("Reopen the chat in Riptide and enable the Riptide extension in Safari.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--key", required=True, help="Riptide’s quoted ssh-ed25519 public key")
    parser.add_argument("--runtime", choices=("hermes", "stdio"), default="hermes",
                        help="Hermes (detects its runtime) or a generic stdio MCP client")
    parser.add_argument("--hermes-config", type=Path, help="config.yaml for a custom Hermes profile")
    parser.add_argument("--authorized-keys", type=Path, help="SSH key file (defaults to ~/.ssh/authorized_keys)")
    args = parser.parse_args()
    if args.hermes_config and args.runtime != "hermes":
        parser.error("--hermes-config requires --runtime hermes")
    if not sys.platform.startswith("linux") or sys.version_info < (3, 11):
        parser.error("Linux with a systemd user manager and Python 3.11+ is required. See the README for manual setup.")
    try:
        install(args, Path.home().resolve())
    except subprocess.CalledProcessError as exc:
        if exc.cmd[:2] == ["systemctl", "--user"]:
            parser.exit(1, f"Could not manage the systemd user relay. Run from a login shell as the agent’s OS account.\n"
                           f"{(exc.stderr or '').strip()}\n")
        parser.exit(1, "Could not install the Safari MCP Python environment. Install Python venv and retry.\n")
    except subprocess.TimeoutExpired:
        parser.exit(1, "The selected SSH command timed out while checking the Safari relay.\n")
    except (ValueError, OSError) as exc:
        parser.exit(1, f"{exc}\n")


if __name__ == "__main__":
    main()
