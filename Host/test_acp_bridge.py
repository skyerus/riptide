import json
import sys
import unittest

from websockets.asyncio.client import connect
from websockets.exceptions import InvalidStatus

from acp_bridge import bridge_server


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
