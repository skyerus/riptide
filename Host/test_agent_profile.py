import argparse
import asyncio
from functools import partial
import json
import os
from pathlib import Path
import select
import ssl
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from websockets.asyncio.client import connect
from websockets.asyncio.server import serve

from acp_bridge import bridge_server
from agent_profile import PROFILE_UPDATE, RENAME, call_tool, read_name

HOST = Path(__file__).resolve().parent
WORKSPACE = "/riptide-profile-fixture"
NEW_NAME = "Harbor"
FIXTURE_AGENT = """
import json, subprocess, sys
connector = None
workspace = sys.argv[1]
def emit(frame):
    print(json.dumps({"jsonrpc": "2.0", **frame}), flush=True)
for line in sys.stdin:
    packet = json.loads(line)
    method = packet["method"]
    if method == "initialize":
        result = {"protocolVersion": 1, "agentCapabilities": {
            "loadSession": True, "sessionCapabilities": {"list": {}}
        }}
    elif method == "session/list":
        result = {"sessions": [{"sessionId": "main", "cwd": workspace, "title": "Main Chat"}]}
    elif method in ("session/new", "session/load"):
        connector, = packet["params"]["mcpServers"]
        result = {"sessionId": "main"}
    elif method == "session/prompt":
        emit({"method": "_riptide/agent/profile", "params": {"name": "Untrusted agent frame"}})
        def request(id, method, params):
            return json.dumps({"jsonrpc": "2.0", "id": id, "method": method, "params": params}) + "\\n"
        frames = request(1, "initialize", {"protocolVersion": "2025-11-25", "capabilities": {}})
        frames += request(2, "tools/call", {"name": "set_display_name", "arguments": {"name": "Harbor"}})
        mcp = subprocess.run([connector["command"], *connector["args"]], input=frames,
                             text=True, capture_output=True, check=True, timeout=5)
        reply = json.loads(mcp.stdout.splitlines()[1])["result"]
        assert not reply["isError"], reply
        emit({"method": "session/update", "params": {"sessionId": "main", "update": {
            "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "My name is Harbor."}
        }}})
        result = {"stopReason": "end_turn"}
    else:
        continue
    emit({"id": packet["id"], "result": result})
"""


def request(id, method, **params):
    return {"jsonrpc": "2.0", "id": id, "method": method, "params": params}


class AgentProfileTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.state = self.root / "name.json"

    def test_rejects_invalid_names_and_other_agent_targets(self):
        self.assertEqual(call_tool(self.state, RENAME, {"name": "  Harbor ⚓  "}, None), {"name": "Harbor ⚓"})
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)
        for args in ({"name": " "}, {"name": "a" * 81}, {"name": "Harbor\nDock"},
                     {"name": "\ud800"}, {"name": "New", "agent": "another"}):
            self.assertIn("error", call_tool(self.state, RENAME, args, None))
        other = self.root / "different-agent.json"
        self.assertEqual(call_tool(other, RENAME, {"name": "Dock"}, None), {"name": "Dock"})
        self.assertEqual(read_name(self.state), "Harbor ⚓")
        self.assertEqual(read_name(other), "Dock")

    def test_ssh_tool_pushes_name_and_reconnect_replays_it(self):
        def start():
            return self.enterContext(subprocess.Popen(
                [sys.executable, str(HOST / "ssh_acp.py"), "--workspace", str(self.root),
                 "--agent-profile-state", str(self.state), "--", sys.executable, "-c", FIXTURE_AGENT, str(self.root)],
                env={**os.environ, "SSH_ORIGINAL_COMMAND": "riptide-acp"},
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0,
            ))

        def send(process, packet):
            process.stdin.write((json.dumps(packet) + "\n").encode())

        def receive(process):
            self.assertTrue(select.select([process.stdout], [], [], 5)[0], "No SSH ACP frame")
            return json.loads(process.stdout.readline())

        process = start()
        try:
            send(process, request(1, "initialize", protocolVersion=1, clientCapabilities={}))
            self.assertEqual(receive(process)["id"], 1)
            send(process, request(2, "session/load", cwd=str(self.root), sessionId="main", mcpServers=[]))
            self.assertEqual(receive(process)["result"]["sessionId"], "main")
            send(process, request(3, "session/prompt", sessionId="main", prompt=[{"type": "text", "text": "Rename"}]))
            frames = [receive(process) for _ in range(3)]
            updates = [frame["params"]["name"] for frame in frames if frame.get("method") == PROFILE_UPDATE]
            self.assertEqual(updates, [NEW_NAME])
        finally:
            process.stdin.close()
            process.wait(timeout=5)

        reconnected = start()
        try:
            send(reconnected, request(1, "initialize", protocolVersion=1, clientCapabilities={}))
            self.assertEqual(receive(reconnected)["id"], 1)
            self.assertEqual(receive(reconnected)["params"], {"name": NEW_NAME})
        finally:
            reconnected.stdin.close()
            reconnected.wait(timeout=5)

    async def test_websocket_attaches_the_same_tool_and_pushes_the_name(self):
        token = "a" * 50
        command = (sys.executable, "-c", FIXTURE_AGENT, WORKSPACE)
        async with bridge_server(0, token, command, profile_state=self.state) as server:
            base = f"ws://127.0.0.1:{server.sockets[0].getsockname()[1]}"
            async with (connect(f"{base}/acp", additional_headers={"Authorization": f"Bearer {token}"}) as socket,
                        asyncio.timeout(5)):
                await socket.send(json.dumps(request(1, "initialize")))
                self.assertEqual(json.loads(await socket.recv())["id"], 1)
                await socket.send(json.dumps(request(2, "session/load", cwd=WORKSPACE, sessionId="main", mcpServers=[])))
                self.assertEqual(json.loads(await socket.recv())["id"], 2)
                await socket.send(json.dumps(request(3, "session/prompt", sessionId="main", prompt=[])))
                frames = [json.loads(await socket.recv()) for _ in range(3)]
                updates = [frame["params"]["name"] for frame in frames if frame.get("method") == PROFILE_UPDATE]
                self.assertEqual(updates, [NEW_NAME])
                self.assertEqual(read_name(self.state), NEW_NAME)


async def run_ui_fixture(cert, key, port_file):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    command = (sys.executable, "-c", FIXTURE_AGENT, WORKSPACE)
    with tempfile.TemporaryDirectory() as directory, patch("acp_bridge.serve", partial(serve, ssl=context)):
        state = Path(directory) / "name.json"
        async with bridge_server(0, "a" * 50, command, profile_state=state) as server:
            port_file.write_text(str(server.sockets[0].getsockname()[1]))
            await server.serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run the loopback agent rename fixture for iPhone UI tests.")
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--port-file", required=True, type=Path)
    args = parser.parse_args()
    asyncio.run(run_ui_fixture(args.cert, args.key, args.port_file))
