import argparse
import asyncio
import base64
from functools import partial
from io import BytesIO
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
from uuid import UUID

from PIL import Image, ImageDraw
from websockets.asyncio.client import connect
from websockets.asyncio.server import serve

from acp_bridge import bridge_server
from agent_profile import PROFILE_UPDATE, RENAME, SET_PHOTO, call_tool, read_name, read_photo

HOST = Path(__file__).resolve().parent
WORKSPACE = "/riptide-profile-fixture"
NEW_NAME = "Harbor"
PHOTO_REQUEST = "Set your profile picture"
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
        emit({"method": "_riptide/agent/profile", "params": {"name": "Untrusted agent frame",
              "photo": {"revision": "00000000-0000-0000-0000-000000000000", "dataBase64": "dGVzdA=="}}})
        wants_photo = any(block.get("text") == "Set your profile picture" for block in packet["params"]["prompt"])
        name, arguments = ("set_profile_photo", {"filename": "avatar.png"}) if wants_photo else (
            "set_display_name", {"name": "Harbor"})
        def request(id, method, params):
            return json.dumps({"jsonrpc": "2.0", "id": id, "method": method, "params": params}) + "\\n"
        frames = request(1, "initialize", {"protocolVersion": "2025-11-25", "capabilities": {}})
        frames += request(2, "tools/call", {"name": name, "arguments": arguments})
        mcp = subprocess.run([connector["command"], *connector["args"]], input=frames,
                             text=True, capture_output=True, check=True, timeout=5)
        reply = json.loads(mcp.stdout.splitlines()[1])["result"]
        assert not reply["isError"], reply
        emit({"method": "session/update", "params": {"sessionId": "main", "update": {
            "sessionUpdate": "agent_message_chunk", "content": {"type": "text",
                "text": "I updated my profile picture." if wants_photo else "My name is Harbor."}
        }}})
        result = {"stopReason": "end_turn"}
    else:
        continue
    emit({"id": packet["id"], "result": result})
"""


def request(id, method, **params):
    return {"jsonrpc": "2.0", "id": id, "method": method, "params": params}


def fixture_photo(directory):
    image = Image.new("RGB", (660, 550), "#132b3d")
    draw = ImageDraw.Draw(image)
    draw.ellipse((110, 56, 550, 496), fill="#65d8be")
    draw.ellipse((258, 88, 550, 380), fill="#132b3d")
    draw.ellipse((366, 230, 416, 280), fill="#f8cc77")
    image.save(directory / "avatar.png")


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

    def test_photo_accepts_only_an_owned_image_in_the_paired_workspace(self):
        workspace = self.root / "work"
        workspace.mkdir()
        fixture_photo(workspace)
        (workspace / "secret.png").write_text("not an image")
        (workspace / "linked.png").symlink_to(workspace / "avatar.png")
        os.mkfifo(workspace / "pipe.png")
        change = partial(call_tool, self.state, SET_PHOTO, workspace=workspace, _elicit=None)
        for invalid in ({"filename": x} for x in ["../avatar.png", str(workspace / "avatar.png"), "secret.png",
                                                    "linked.png", "pipe.png", "missing.png", "\ud800"]):
            self.assertIn("error", change(invalid), invalid)
        self.assertEqual(change({"filename": "avatar.png"}), {"updated": True})
        revision, data = read_photo(self.state)
        with Image.open(BytesIO(data)) as photo:
            self.assertEqual((photo.format, photo.size), ("JPEG", (512, 512)))
        self.assertIsNone(read_photo(self.root / "other.json"))
        self.assertEqual(self.state.with_suffix(".json.avatar").stat().st_mode & 0o777, 0o600)
        self.assertEqual(change({"filename": "avatar.png"}), {"updated": True})
        self.assertNotEqual(read_photo(self.state)[0], revision)

    def test_ssh_tool_pushes_profile_updates_and_reconnect_replays_them(self):
        fixture_photo(self.root)
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
            send(process, request(4, "session/prompt", sessionId="main", prompt=[{"type": "text", "text": PHOTO_REQUEST}]))
            updates = [frame["params"] for frame in (receive(process) for _ in range(3)) if frame.get("method") == PROFILE_UPDATE]
            self.assertEqual(len(updates), 1)
            saved_photo = updates[0]["photo"]
            self.assertEqual((UUID(saved_photo["revision"]), base64.b64decode(saved_photo["dataBase64"])), read_photo(self.state))
        finally:
            process.stdin.close()
            process.wait(timeout=5)

        reconnected = start()
        try:
            send(reconnected, request(1, "initialize", protocolVersion=1, clientCapabilities={}))
            self.assertEqual(receive(reconnected)["id"], 1)
            self.assertEqual(receive(reconnected)["params"], {"name": NEW_NAME})
            self.assertEqual(receive(reconnected)["params"], {"photo": saved_photo})
        finally:
            reconnected.stdin.close()
            reconnected.wait(timeout=5)

    async def test_websocket_attaches_the_same_tools_and_pushes_profile_updates(self):
        fixture_photo(self.root)
        token = "a" * 50
        command = (sys.executable, "-c", FIXTURE_AGENT, WORKSPACE)
        async with bridge_server(0, token, command, profile_state=self.state, profile_workspace=self.root) as server:
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
                await socket.send(json.dumps(request(4, "session/prompt", sessionId="main",
                                                     prompt=[{"type": "text", "text": PHOTO_REQUEST}])))
                frames = [json.loads(await socket.recv()) for _ in range(3)]
                updates = [frame["params"]["photo"] for frame in frames if frame.get("method") == PROFILE_UPDATE]
                photo, = updates
                self.assertEqual((UUID(photo["revision"]), base64.b64decode(photo["dataBase64"])), read_photo(self.state))


async def run_ui_fixture(cert, key, port_file):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    command = (sys.executable, "-c", FIXTURE_AGENT, WORKSPACE)
    with tempfile.TemporaryDirectory() as directory, patch("acp_bridge.serve", partial(serve, ssl=context)):
        workspace = Path(directory)
        fixture_photo(workspace)
        state = workspace / "name.json"
        async with bridge_server(0, "a" * 50, command, profile_state=state, profile_workspace=workspace) as server:
            port_file.write_text(str(server.sockets[0].getsockname()[1]))
            await server.serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run the loopback agent profile fixture for iPhone UI tests.")
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--port-file", required=True, type=Path)
    args = parser.parse_args()
    asyncio.run(run_ui_fixture(args.cert, args.key, args.port_file))
