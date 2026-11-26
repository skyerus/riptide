"""Prepare a trusted Hermes profile for Chrome computer use."""

import argparse
from contextlib import ExitStack
from dataclasses import dataclass
from io import StringIO
import os
from pathlib import Path
import re
import stat

from ssh_pairing_files import Edit, read_owned, require

PROFILE = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}")
CHROME = Path("/usr/bin/google-chrome-stable")
SKILL = Path("skills/riptide-browser-handoff/SKILL.md")


def absolute_path(value):
    require(isinstance(value, str) and not any(c in value for c in "\x00\r\n"),
            "Invalid on-host pairing configuration.")
    path = Path(value)
    require(path.is_absolute(), "Pairing paths must be absolute.")
    return path


def owned_directory(path):
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o022,
            f"Use an owner-controlled directory at {path}.")


@dataclass(frozen=True)
class ChromePolicy:
    home: Path
    python: Path
    source: Path

    @classmethod
    def from_config(cls, config):
        require(isinstance(config, dict) and set(config) == {"home", "python", "source"},
                "Invalid Hermes Chrome policy.")
        policy = cls(*(absolute_path(config[key]) for key in ("home", "python", "source")))
        owned_directory(policy.home)
        owned_directory(policy.source)
        require(os.access(policy.python, os.X_OK), "The Hermes Python executable is unavailable.")
        return policy

    def profile_home(self, profile):
        require(PROFILE.fullmatch(profile), "Invalid Hermes profile.")
        if profile == "default":
            return self.home
        owned_directory(self.home / "profiles")
        path = self.home / "profiles" / profile
        owned_directory(path)
        return path

    def options(self, home, hermes):
        return ["--hermes-screen", str(home), str(hermes), "--hermes-browser-mcp", str(self.python), str(self.source)]


def profile_edits(home, skill_source, chrome=CHROME):
    from ruamel.yaml import YAML

    owned_directory(home)
    path = home / "config.yaml"
    before, mode = read_owned(path)
    require(before is not None, f"Hermes config is missing at {path}.")
    yaml = YAML()
    yaml.preserve_quotes = True
    config = yaml.load(before.decode()) or {}
    require(isinstance(config, dict), "Hermes config must be a mapping.")
    changed = isinstance(config.get("model"), str)
    if changed:
        config["model"] = {"default": config["model"]} if config["model"] else {}
    for section, key, value in (("browser", "executable_path", str(chrome)),
                                ("bot_desktop", "auto_start", True),
                                ("model", "openai_runtime", "codex_app_server")):
        if config.get(section) is None:
            config[section] = {}
        require(isinstance(config[section], dict), f"Hermes {section} settings must be a mapping.")
        if config[section].get(key) != value:
            config[section][key] = value
            changed = True
    edits = []
    if changed:
        output = StringIO()
        yaml.dump(config, output)
        edits.append(Edit(path, before, output.getvalue().encode(), mode))

    skill = home / SKILL
    for parent in (skill.parent.parent, skill.parent):
        parent.mkdir(exist_ok=True, mode=0o700)
        owned_directory(parent)
    existing, mode = read_owned(skill)
    desired = skill_source.read_bytes()
    if existing != desired:
        edits.append(Edit(skill, existing, desired, mode))
    return edits


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", type=Path)
    parser.add_argument("skill", type=Path)
    args = parser.parse_args()
    try:
        require(args.profile.is_absolute() and args.skill.is_absolute(), "Use absolute profile and skill paths.")
        require(os.access(CHROME, os.X_OK), "Chrome Stable is unavailable on the Hermes host.")
        with ExitStack() as rollback:
            for edit in profile_edits(args.profile, args.skill):
                edit.apply(rollback)
            rollback.pop_all()
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
