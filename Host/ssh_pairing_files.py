#!/usr/bin/env python3
"""Read and update owner-controlled files and restricted SSH key commands."""

from dataclasses import dataclass
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import tempfile


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


@dataclass
class Edit:
    path: Path
    before: bytes | None
    after: bytes
    mode: int

    def replace(self, expected, content):
        require(read_owned(self.path)[0] == expected, f"{self.path} changed during the update. Retry.")
        if content is None:
            self.path.unlink()
            return
        fd, name = tempfile.mkstemp(dir=self.path.parent, prefix=".riptide-edit-")
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
    return key


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
