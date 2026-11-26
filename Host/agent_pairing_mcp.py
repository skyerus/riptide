"""Offer configured Riptide agents and request device consent over MCP stdio."""

import argparse
import json
from functools import partial
from pathlib import Path
import sys

from hermes_pairing import PROFILE
from ssh_pairing_files import read_owned
from mcp_stdio import MCPServer

SERVER = "riptide_pairing"
LIST = "list_pairable_agents"
REQUEST = "request_agent_pairing"
TOOLS = [
    {
        "name": LIST,
        "description": "List agents this Riptide connection is allowed to pair by name and profile ID.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": REQUEST,
        "description": (
            "When the user asks to connect an agent to Riptide, request their approval in the current chat. "
            "Use a profile ID from list_pairable_agents. For multiple agents, call once per agent in sequence. "
            "Report an agent connected only if this tool returns paired. Never ask for keys or chat IDs."
        ),
        "inputSchema": {
            "type": "object", "required": ["profile"], "additionalProperties": False,
            "properties": {"profile": {"type": "string"}},
        },
    },
]


def targets(config):
    raw, _ = read_owned(config)
    configured = json.loads(raw)["targets"]
    return {profile: target["name"] for profile, target in configured.items()
            if PROFILE.fullmatch(profile) and isinstance(target, dict)
            and isinstance(target.get("name"), str) and 0 < len(target["name"]) <= 80}


def pairing_form(profile, name):
    return {
        "mode": "form",
        "message": f"Connect {name} to Riptide?",
        "requestedSchema": {
            "type": "object",
            # An optional single choice maps Riptide's Skip to an empty answer.
            "properties": {"pair": {"type": "string", "enum": [f"Pair Hermes profile: {profile}"]}},
        },
    }


def call_tool(config, name, arguments, elicit):
    if name == REQUEST and elicit is None:
        return {"error": "This chat does not support pairing approval."}
    try:
        configured = targets(config)
    except (OSError, ValueError, TypeError, AttributeError, KeyError):
        return {"error": "Riptide pairing configuration is unavailable."}
    if name == LIST and arguments == {}:
        return {"agents": [{"profile": profile, "name": label} for profile, label in configured.items()]}
    if name != REQUEST or not isinstance(arguments, dict) or set(arguments) != {"profile"}:
        return {"error": "Invalid pairing tool call."}
    profile = arguments["profile"]
    if not isinstance(profile, str) or profile not in configured:
        return {"error": "Choose a profile from the agents available to this Riptide connection."}
    form = pairing_form(profile, configured[profile])
    answer = elicit(form) or {}
    content = answer.get("content")
    status = "cancelled"
    if answer.get("action") == "accept":
        choice = form["requestedSchema"]["properties"]["pair"]["enum"][0]
        status = "paired" if content == {"pair": choice} else "skipped"
    elif answer.get("action") == "decline":
        status = "skipped"
    return {"profile": profile, "status": status}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    if not args.config.is_absolute():
        parser.error("Use an absolute pairing manifest path.")
    MCPServer(SERVER, TOOLS, partial(call_tool, args.config), sys.stdin.buffer, sys.stdout.buffer).serve()
