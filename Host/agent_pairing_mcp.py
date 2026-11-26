"""Offer configured Riptide agents and request device consent over MCP stdio."""

import argparse
import json
from pathlib import Path
import sys
from uuid import uuid4

from hermes_pairing import PROFILE
from install_safari import read_owned

SERVER = "riptide_pairing"
LIST = "list_pairable_agents"
REQUEST = "request_agent_pairing"
MAX_FRAME = 64 * 1024
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


class PairingServer:
    def __init__(self, config, reader, writer):
        self.config = config
        self.reader = reader
        self.writer = writer
        self.can_elicit = False

    def send(self, frame):
        self.writer.write(json.dumps({"jsonrpc": "2.0", **frame}).encode() + b"\n")
        self.writer.flush()

    def read(self):
        line = self.reader.readline(MAX_FRAME)
        return json.loads(line) if line.endswith(b"\n") else None

    def elicit(self, tool_request_id, form):
        request_id = "pairing-" + uuid4().hex
        self.send({"id": request_id, "method": "elicitation/create", "params": form})
        while request := self.read():
            if "method" not in request and request.get("id") == request_id:
                result = request.get("result")
                return result if isinstance(result, dict) else None
            if (request.get("method") == "notifications/cancelled"
                    and request.get("params", {}).get("requestId") == tool_request_id):
                self.send({"method": "notifications/cancelled", "params": {"requestId": request_id}})
                return None
            # A host can ping or discover tools while waiting for a human.
            self.receive(request, pending=True)
        return None

    def receive(self, request, pending=False):
        method = request.get("method")
        if method is None or "id" not in request:
            return
        request_id = request["id"]
        params = request.get("params", {})
        if method == "initialize" and not pending:
            version = params.get("protocolVersion")
            if version not in ("2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"):
                version = "2025-06-18"
            self.can_elicit = (version >= "2025-06-18"
                               and "elicitation" in params.get("capabilities", {}))
            result = {"protocolVersion": version, "capabilities": {"tools": {}},
                      "serverInfo": {"name": SERVER, "version": "1.0.0"}}
        elif method == "ping":
            result = {}
        elif method == "tools/list":
            result = {"tools": TOOLS}
        elif method == "tools/call" and not pending:
            tool = params.get("name")
            if tool == REQUEST and not self.can_elicit:
                reply = {"error": "This chat does not support pairing approval."}
            else:
                reply = call_tool(self.config, tool, params.get("arguments", {}),
                                  lambda form: self.elicit(request_id, form))
            result = {"content": [{"type": "text", "text": json.dumps(reply)}], "isError": "error" in reply}
        else:
            self.send({"id": request_id, "error": {"code": -32601, "message": "Method unavailable"}})
            return
        self.send({"id": request_id, "result": result})

    def serve(self):
        while request := self.read():
            self.receive(request)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    if not args.config.is_absolute():
        parser.error("Use an absolute pairing manifest path.")
    PairingServer(args.config, sys.stdin.buffer, sys.stdout.buffer).serve()
