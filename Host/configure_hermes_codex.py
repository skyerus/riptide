#!/usr/bin/env python3
"""Configure Codex App Server for the default and named Hermes profiles."""

import argparse
from contextlib import ExitStack
from io import BytesIO
import json
from pathlib import Path
import shutil
import tomllib

from ruamel.yaml import YAML, YAMLError

from hermes_pairing import PROFILE
from install_safari import Edit, read_owned, require


RUNTIME = "codex_app_server"
CODEX_PERMISSIONS = {
    "default_permissions": ":workspace",
    "approval_policy": "on-request",
    "approvals_reviewer": "auto_review",
}


def configure(home, codex_config, fallback_binary, apply=False):
    source, _ = read_owned(codex_config)
    require(source is not None, f"Configure Codex permissions at {codex_config} first.")
    permissions = tomllib.loads(source.decode())
    for key, expected in CODEX_PERMISSIONS.items():
        require(permissions.get(key) == expected, f"Set {key} = {expected!r} in {codex_config}.")

    profiles = home / "profiles"
    named = []
    if profiles.is_dir():
        named = sorted(path for path in profiles.iterdir() if path.is_dir() and PROFILE.fullmatch(path.name))
    yaml = YAML()
    yaml.preserve_quotes = True
    edits = []
    planned = []
    default_binary = fallback_binary
    for profile in [home, *named]:
        path = profile / "config.yaml"
        before, mode = read_owned(path)
        require(before is not None, f"The Hermes profile has no config at {path}.")
        config = yaml.load(BytesIO(before))
        model = config.get("model") if isinstance(config, dict) else None
        require(isinstance(model, dict) and model.get("provider") in {"openai", "openai-codex"},
                f"Configure a Codex-compatible model provider at {path} before switching runtimes.")
        binary = model.get("codex_bin") or default_binary
        require(isinstance(binary, str) and Path(binary).is_absolute() and shutil.which(binary),
                f"Use an absolute, executable Codex launcher at {path}.")
        if profile == home:
            default_binary = binary
        changed = model.get("openai_runtime") != RUNTIME or model.get("codex_bin") != binary
        if changed:
            model["codex_bin"] = binary
            model["openai_runtime"] = RUNTIME
            revised = BytesIO()
            yaml.dump(config, revised)
            edits.append(Edit(path, before, revised.getvalue(), mode))
        planned.append({"profile": "default" if profile == home else profile.name,
                        "runtime": RUNTIME, "changed": changed})

    if apply:
        with ExitStack() as rollback:
            for edit in edits:
                edit.apply(rollback)
            rollback.pop_all()
    return planned


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hermes-home", type=Path, required=True, help="Default profile containing profiles/.")
    parser.add_argument("--codex-config", type=Path, required=True)
    parser.add_argument("--codex-bin", required=True, help="Fallback absolute Codex executable.")
    parser.add_argument("--apply", action="store_true", help="Write the configuration instead of printing the plan.")
    args = parser.parse_args()
    try:
        result = configure(args.hermes_home.resolve(), args.codex_config, args.codex_bin, args.apply)
    except YAMLError:
        parser.exit(1, "Could not parse a Hermes YAML configuration.\n")
    except tomllib.TOMLDecodeError:
        parser.exit(1, "Could not parse the Codex configuration.\n")
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")
    print(json.dumps({"applied": args.apply, "profiles": result}, indent=2))


if __name__ == "__main__":
    main()
