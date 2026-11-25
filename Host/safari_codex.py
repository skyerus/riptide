"""Start Codex with Safari MCP for an explicitly configured SSH chat."""

import json
import os
from pathlib import Path
import sys


def command_with_safari(arguments, connector_python, state_dir):
    if arguments[:1] != ["app-server"] or (connector_python is None and state_dir is None):
        return arguments
    if not connector_python or not state_dir or not all(map(os.path.isabs, (connector_python, state_dir))):
        raise ValueError("Use absolute Python and relay state paths for Riptide Safari.")
    connector = str(Path(__file__).resolve().with_name("safari_mcp.py"))
    settings = {
        "command": connector_python,
        "args": [connector, "--state-dir", state_dir],
        "tool_timeout_sec": 90,
    }
    return arguments + [
        argument
        for name, value in settings.items()
        for argument in ("-c", f"mcp_servers.riptide_safari.{name}={json.dumps(value)}")
    ]


if __name__ == "__main__":
    if len(sys.argv) < 2 or not os.path.isabs(sys.argv[1]):
        sys.exit("An absolute path to the Codex executable is required.")
    codex = sys.argv[1]
    connector_python = os.environ.pop("RIPTIDE_SAFARI_CODEX_PYTHON", None)
    state_dir = os.environ.pop("RIPTIDE_SAFARI_CODEX_STATE_DIR", None)
    try:
        arguments = command_with_safari(sys.argv[2:], connector_python, state_dir)
    except ValueError as error:
        sys.exit(str(error))
    os.execv(codex, [codex, *arguments])
