"""Prepare a trusted Hermes profile for Chrome computer use."""

import argparse
from contextlib import ExitStack, contextmanager
from dataclasses import dataclass
import fcntl
from io import StringIO
import json
import os
from pathlib import Path
import stat

from ssh_pairing_files import Edit, PROFILE, read_owned, require

CHROME = Path("/usr/bin/google-chrome-stable")
SKILL = Path("skills/riptide-browser-handoff/SKILL.md")
SHARED_BROWSER = "riptide-shared-browser.json"


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
class SharedBrowser:
    home: Path
    lock: Path

    @contextmanager
    def turn(self):
        # All admitted MCP connectors for this screen share one ordering. A
        # capture from one connector cannot authorize input after another
        # connector has taken an action, even when Hermes still says "agent".
        with os.fdopen(os.open(self.lock, os.O_CREAT | os.O_NOFOLLOW | os.O_RDWR, 0o600), "r+") as stream:
            info = os.fstat(stream.fileno())
            require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o022,
                    "Invalid shared Chrome operation lock.")
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            generation = int(stream.read() or "0") + 1
            stream.seek(0)
            stream.write(str(generation))
            stream.truncate()
            stream.flush()
            yield generation


@dataclass(frozen=True)
class BrowserRoute:
    shared: SharedBrowser | None = None
    sharing_configured: bool = False


def profile_slug(home):
    home = Path(home)
    return home.name if home.parent.name == "profiles" else "default"


def paired_targets(manifest_path, root):
    source, _ = read_owned(absolute_path(manifest_path))
    require(source is not None, "The shared Chrome pairing manifest is missing.")
    manifest = json.loads(source)
    require(isinstance(manifest, dict) and isinstance(manifest.get("targets"), dict)
            and isinstance(manifest.get("chrome"), dict)
            and absolute_path(manifest["chrome"].get("home")).resolve() == root.resolve(),
            "Use a Chrome-enabled pairing manifest for this Hermes home.")
    return manifest["targets"]


def browser_route(profile_home):
    """Resolve the desktop from host policy and the fixed Riptide pairing."""
    home = Path(profile_home)
    named = home.parent.name == "profiles"
    root = home.parent.parent if named else home
    source, _ = read_owned(root / SHARED_BROWSER)
    if source is None:
        return BrowserRoute()
    owned_directory(root)
    config = json.loads(source)
    require(isinstance(config, dict) and {"owner", "members"} <= config.keys()
            and config.keys() <= {"owner", "members", "pairing_manifest"},
            "Invalid shared Chrome policy.")
    owner, members = config["owner"], config["members"]
    require(isinstance(members, list) and all(isinstance(slug, str) and PROFILE.fullmatch(slug) for slug in members)
            and isinstance(owner, str) and owner in members, "Invalid shared Chrome owner or members.")
    profile = profile_slug(home)
    if profile not in members:
        if "pairing_manifest" not in config or not isinstance(
                paired_targets(config["pairing_manifest"], root).get(profile), dict):
            return BrowserRoute(sharing_configured=True)
    if owner != "default":
        owned_directory(root / "profiles")
    owner_home = root if owner == "default" else root / "profiles" / owner
    owned_directory(owner_home)
    return BrowserRoute(SharedBrowser(owner_home, root / ".riptide-shared-browser.lock"), True)


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
