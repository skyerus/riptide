"""Minimal JSON-RPC stdio transport for Riptide host tools."""

import json
from uuid import uuid4

MAX_FRAME = 64 * 1024


class MCPServer:
    def __init__(self, name, tools, call_tool, reader, writer):
        self.name = name
        self.tools = tools
        self.call_tool = call_tool
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
        request_id = "elicit-" + uuid4().hex
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
                      "serverInfo": {"name": self.name, "version": "1.0.0"}}
        elif method == "ping":
            result = {}
        elif method == "tools/list":
            result = {"tools": self.tools}
        elif method == "tools/call" and not pending:
            elicit = (lambda form: self.elicit(request_id, form)) if self.can_elicit else None
            reply = self.call_tool(params.get("name"), params.get("arguments", {}), elicit)
            result = {"content": [{"type": "text", "text": json.dumps(reply)}], "isError": "error" in reply}
        else:
            self.send({"id": request_id, "error": {"code": -32601, "message": "Method unavailable"}})
            return
        self.send({"id": request_id, "result": result})

    def serve(self):
        while request := self.read():
            self.receive(request)
