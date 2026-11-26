import base64
import json
from pathlib import Path
import shutil
import sys
import unittest
from unittest.mock import AsyncMock, patch

from websockets.asyncio.client import connect
from websockets.exceptions import InvalidStatus

from acp_bridge import bridge_server
from ssh_acp import STAGE_ATTACHMENTS


class ACPBridgeTests(unittest.IsolatedAsyncioTestCase):
    async def test_authentication_and_jsonrpc_round_trip(self):
        token = "a" * 50
        command = (sys.executable, "-u", "-c", "import sys\nfor line in sys.stdin: print(line, end='')")
        async with bridge_server(0, token, command) as server:
            base = f"ws://127.0.0.1:{server.sockets[0].getsockname()[1]}"
            with self.assertRaises(InvalidStatus) as denied:
                async with connect(f"{base}/acp"):
                    self.fail("An unauthenticated socket must not reach ACP.")
            self.assertEqual(denied.exception.response.status_code, 401)
            headers = {"Authorization": f"Bearer {token}"}
            with self.assertRaises(InvalidStatus):
                async with connect(f"{base}/different", additional_headers=headers):
                    self.fail("The bridge must not serve other routes.")
            async with connect(f"{base}/acp", additional_headers=headers) as socket:
                packet = {"jsonrpc": "2.0", "id": 1, "method": "initialize"}
                await socket.send(json.dumps(packet))
                self.assertEqual(json.loads(await socket.recv()), packet)

    async def test_attachments_are_staged_by_the_bridge_after_negotiation(self):
        token = "a" * 50
        agent = """
import json, sys
request = json.loads(sys.stdin.readline())
assert request["method"] == "initialize"
print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": {"protocolVersion": 1}}), flush=True)
for line in sys.stdin:
    raise AssertionError("The attachment request reached the agent subprocess.")
"""
        async with bridge_server(0, token, (sys.executable, "-u", "-c", agent)) as server:
            address = f"ws://127.0.0.1:{server.sockets[0].getsockname()[1]}/acp"
            async with connect(address, additional_headers={"Authorization": f"Bearer {token}"}) as socket:
                await socket.send(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize"}))
                initialized = json.loads(await socket.recv())
                self.assertEqual(initialized["result"]["agentCapabilities"]["_meta"]["riptide.app/attachments"], 1)
                data = b"%PDF-example"
                await socket.send(json.dumps({
                    "jsonrpc": "2.0", "id": 2, "method": STAGE_ATTACHMENTS,
                    "params": {"files": [{"name": "report.pdf", "dataBase64": base64.b64encode(data).decode()}]},
                }))
                response = json.loads(await socket.recv())
                self.assertEqual(response["id"], 2)
                path = Path(response["result"]["paths"][0])
                self.addCleanup(shutil.rmtree, path.parent)
                self.assertEqual(path.read_bytes(), data)

    async def test_dictation_shares_the_authentication_gate_without_starting_acp(self):
        token = "a" * 50
        with patch("codex_dictation.reply", new_callable=AsyncMock, return_value={"text": "Fixture dictation."}) as relay:
            async with bridge_server(0, token, None, "/codex/auth.json") as server:
                base = f"ws://127.0.0.1:{server.sockets[0].getsockname()[1]}"
                with self.assertRaises(InvalidStatus) as denied:
                    async with connect(f"{base}/riptide-dictation"):
                        self.fail("Dictation must require the pairing bearer.")
                self.assertEqual(denied.exception.response.status_code, 401)
                headers = {"Authorization": f"Bearer {token}"}
                with self.assertRaises(InvalidStatus) as missing:
                    async with connect(f"{base}/acp", additional_headers=headers):
                        self.fail("The dictation-only bridge must not serve ACP.")
                self.assertEqual(missing.exception.response.status_code, 404)
                async with connect(f"{base}/riptide-dictation", additional_headers=headers) as socket:
                    await socket.send('{"audio":"fixture"}')
                    self.assertEqual(json.loads(await socket.recv()), {"text": "Fixture dictation."})
                relay.assert_awaited_once_with('{"audio":"fixture"}', "/codex/auth.json")
