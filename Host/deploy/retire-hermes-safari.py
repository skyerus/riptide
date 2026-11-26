"""Remove Riptide Safari settings from explicitly selected Hermes profiles."""

import argparse
from contextlib import ExitStack
from io import StringIO
import os
from pathlib import Path
import sys

from ruamel.yaml import YAML

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ssh_pairing_files import Edit, read_owned, require


def profile_edit(path, launcher, codex):
    before, mode = read_owned(path)
    require(before is not None, f"Missing Hermes config at {path}.")
    yaml = YAML()
    yaml.preserve_quotes = True
    config = yaml.load(before.decode())
    changed = False
    if (model := config.get("model")) and model.get("codex_bin") == str(launcher):
        model["codex_bin"] = str(codex)
        changed = True
    if (servers := config.get("mcp_servers")) and "riptide_safari" in servers:
        del servers["riptide_safari"]
        changed = True
    for tools in (config.get("platform_toolsets") or {}).values():
        if isinstance(tools, list) and "riptide_safari" in tools:
            tools[:] = [tool for tool in tools if tool != "riptide_safari"]
            changed = True
    if not changed:
        return None
    output = StringIO()
    yaml.dump(config, output)
    return Edit(path, before, output.getvalue().encode(), mode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--legacy-launcher", type=Path, required=True)
    parser.add_argument("--codex", type=Path, required=True)
    parser.add_argument("--backup-dir", type=Path, required=True)
    parser.add_argument("configs", type=Path, nargs="+")
    args = parser.parse_args()
    try:
        require(all(p.is_absolute() for p in (args.codex, args.legacy_launcher, args.backup_dir, *args.configs))
                and os.access(args.codex, os.X_OK), "Use absolute paths and a working Codex executable.")
        edits = [edit for path in dict.fromkeys(args.configs)
                 if (edit := profile_edit(path, args.legacy_launcher, args.codex)) is not None]
        if not edits:
            return
        args.backup_dir.mkdir(mode=0o700)
        for edit in edits:
            backup = args.backup_dir / edit.path.relative_to("/")
            backup.parent.mkdir(parents=True, exist_ok=True)
            Edit(backup, None, edit.before, 0o600).apply()
        with ExitStack() as rollback:
            for edit in edits:
                edit.apply(rollback)
            rollback.pop_all()
        print(f"Retired Safari settings in {len(edits)} Hermes profiles. Backups: {args.backup_dir}")
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
