import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest

from agent_pairing_mcp import LIST, REQUEST, SERVER


HOST = Path(__file__).resolve().parent


class PairingMCPTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.config = self.root / "pairing.json"
        self.config.write_text(json.dumps({"targets": {
            "first-accountant": {"name": "First accountant", "mainSessionID": "private"},
            "second-accountant": {"name": "Second accountant"},
        }}))

    def start(self, command, env=None):
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0, env=env)
        self.addCleanup(process.stdout.close)
        self.addCleanup(process.wait, 5)
        self.addCleanup(process.stdin.close)
        return process

    def send(self, process, **packet):
        process.stdin.write((json.dumps({"jsonrpc": "2.0", **packet}) + "\n").encode())
        process.stdin.flush()

    def receive(self, process):
        self.assertTrue(select.select([process.stdout], [], [], 5)[0], "Timed out waiting for a protocol frame")
        return json.loads(process.stdout.readline())

    def call(self, process, request_id, method, **params):
        self.send(process, id=request_id, method=method, params=params)
        return self.receive(process)["result"]

    def connector(self, elicitation=True):
        process = self.start([sys.executable, "-B", str(HOST / "agent_pairing_mcp.py"), "--config", str(self.config)])
        capabilities = {"elicitation": {"form": {}}} if elicitation else {}
        result = self.call(process, 1, "initialize", protocolVersion="2025-11-25", capabilities=capabilities)
        self.assertEqual(result["serverInfo"]["name"], SERVER)
        self.send(process, method="notifications/initialized")
        return process

    def tool_result(self, frame):
        return json.loads(frame["result"]["content"][0]["text"])

    def test_standard_mcp_discovery_and_sequential_device_approvals(self):
        mcp = self.connector()
        tools = self.call(mcp, 2, "tools/list")["tools"]
        self.assertEqual([tool["name"] for tool in tools], [LIST, REQUEST])
        self.send(mcp, id=3, method="tools/call", params={"name": LIST, "arguments": {}})
        listed = self.tool_result(self.receive(mcp))
        self.assertEqual(listed, {"agents": [
            {"profile": "first-accountant", "name": "First accountant"},
            {"profile": "second-accountant", "name": "Second accountant"},
        ]})

        for index, (profile, action, status) in enumerate((
            ("first-accountant", "accept", "paired"), ("second-accountant", "decline", "skipped"),
        ), 4):
            self.send(mcp, id=index, method="tools/call", params={"name": REQUEST, "arguments": {"profile": profile}})
            invitation = self.receive(mcp)
            choice = f"Pair Hermes profile: {profile}"
            self.assertEqual(invitation["method"], "elicitation/create")
            self.assertEqual(invitation["params"]["requestedSchema"]["properties"]["pair"]["enum"], [choice])
            self.send(mcp, id=invitation["id"], result={
                "action": action, **({"content": {"pair": choice}} if action == "accept" else {}),
            })
            self.assertEqual(self.tool_result(self.receive(mcp)), {"profile": profile, "status": status})

    def test_rejects_unlisted_targets_and_clients_without_approval_support(self):
        for elicitation, profile in ((True, "unlisted"), (False, "first-accountant")):
            mcp = self.connector(elicitation)
            self.send(mcp, id=2, method="tools/call", params={"name": REQUEST, "arguments": {"profile": profile}})
            reply = self.receive(mcp)
            self.assertEqual(reply["id"], 2)
            self.assertTrue(reply["result"]["isError"])

    def test_cancelling_tool_releases_the_pending_form_and_next_request_works(self):
        mcp = self.connector()
        self.send(mcp, id=2, method="tools/call", params={"name": REQUEST, "arguments": {"profile": "first-accountant"}})
        invitation = self.receive(mcp)
        self.send(mcp, method="notifications/cancelled", params={"requestId": 2})
        cancelled = self.receive(mcp)
        self.assertEqual(cancelled["method"], "notifications/cancelled")
        self.assertEqual(cancelled["params"]["requestId"], invitation["id"])
        self.assertEqual(self.tool_result(self.receive(mcp))["status"], "cancelled")
        self.assertEqual(self.call(mcp, 3, "ping"), {})

    def test_ssh_connector_scope_preserves_safari_and_stays_stable_across_reconnects(self):
        agent = ("import json, sys\n"
                 "for line in sys.stdin:\n"
                 "    frame = json.loads(line)\n"
                 "    print(json.dumps({'id': frame['id'], 'result': frame['params']}), flush=True)\n")
        wrapper = HOST / "ssh_acp.py"
        browser = self.root / "browser.sock"
        flags = ["--safari", str(browser), "device", "--safari-mcp-python", sys.executable]
        previous = None
        for pairing in (True, True, False):
            args = [*flags, "--pairing-config", str(self.config)] if pairing else flags
            acp = self.start([sys.executable, str(wrapper), "--workspace", str(self.root), *args,
                              "--", sys.executable, "-c", agent], {**os.environ, "SSH_ORIGINAL_COMMAND": "riptide-acp"})
            enabled = self.call(acp, 2, "session/load", cwd=str(self.root), sessionId="main", mcpServers=[])["mcpServers"]
            self.assertEqual([server["name"] for server in enabled], ["riptide_safari", SERVER] if pairing else ["riptide_safari"])
            if pairing:
                self.assertEqual(enabled[1]["args"], [str(HOST / "agent_pairing_mcp.py"), "--config", str(self.config)])
                if previous is not None:
                    self.assertEqual(previous, enabled)
                previous = enabled
