import base64
import json
import os
from pathlib import Path
import select
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

from ssh_acp import STAGE_ATTACHMENTS, admitted, stage_attachments


class SSHACPPolicyTests(unittest.TestCase):
    def test_known_session_methods_and_permission_answers(self):
        workspace = "/agent/workspace"
        for method, params in (
            ("initialize", {"protocolVersion": 1, "clientCapabilities": {}}),
            ("session/list", {}),
            ("session/new", {"cwd": workspace, "mcpServers": []}),
            ("session/load", {"cwd": workspace, "sessionId": "main", "mcpServers": []}),
            ("session/prompt", {"sessionId": "main", "prompt": [{"type": "text", "text": "Hello"}]}),
            ("_riptide/session/steer", {"sessionId": "main", "text": "Focus on the draft"}),
            ("session/set_config_option", {"sessionId": "main", "configId": "model", "value": "default"}),
        ):
            with self.subTest(method=method):
                self.assertTrue(admitted({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}, workspace, set()))
        pending = {2}
        response = {"jsonrpc": "2.0", "id": 2, "result": {"outcome": {"outcome": "cancelled"}}}
        self.assertTrue(admitted(response, workspace, pending))
        self.assertFalse(admitted(response, workspace, pending))

    def test_staging_preserves_bytes_and_limits_filenames_and_permissions(self):
        data = b"%PDF-example"
        attachment = {"name": "report.pdf", "dataBase64": base64.b64encode(data).decode()}
        packet = {"jsonrpc": "2.0", "id": 9, "method": STAGE_ATTACHMENTS, "params": {"files": [attachment]}}
        reply = stage_attachments(packet)
        path = Path(reply["result"]["paths"][0])
        self.addCleanup(shutil.rmtree, path.parent)
        self.assertEqual(path.read_bytes(), data)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
        for invalid in (
            {**attachment, "name": "../report.pdf"},
            {**attachment, "dataBase64": "invalid%"},
            {**attachment, "dataBase64": base64.b64encode(b"x" * (1024 * 1024 + 1)).decode()},
        ):
            packet["params"]["files"] = [invalid]
            self.assertEqual(stage_attachments(packet)["error"]["code"], -32602)

    def test_prompt_admits_inline_images_with_the_expected_shape(self):
        image = {"type": "image", "mimeType": "image/png", "data": base64.b64encode(b"\x89PNG\r\n\x1a\n").decode()}
        packet = {"jsonrpc": "2.0", "id": 8, "method": "session/prompt", "params": {"sessionId": "main", "prompt": [image]}}
        self.assertTrue(admitted(packet, "/agent/workspace", set()))
        packet["params"]["prompt"] = [{**image, "uri": "file:///example"}]
        self.assertFalse(admitted(packet, "/agent/workspace", set()))

    def test_cannot_request_extra_capabilities_or_bypass_workspace(self):
        workspace = "/agent/workspace"
        for method, params in (
            ("initialize", {"protocolVersion": 1, "clientCapabilities": {"terminal": True}}),
            ("session/new", {"cwd": workspace, "mcpServers": [{"name": "extra"}]}),
            ("session/load", {"cwd": "/", "sessionId": "main", "mcpServers": []}),
            ("session/load", {"cwd": workspace, "sessionId": "main", "mcpServers": [], "_meta": {}}),
            ("session/set_config_option", {"sessionId": "main", "configId": "mode", "value": "unconfigured"}),
            ("session/prompt", {"sessionId": "main", "prompt": [{"type": "resource", "uri": "file:///example"}]}),
            ("_riptide/session/steer", {"sessionId": "main", "text": " ", "cwd": "/"}),
            ("other/method", {}),
        ):
            with self.subTest(method=method):
                self.assertFalse(admitted({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}, workspace, set()))

    def test_safari_mcp_is_only_injected_into_admitted_sessions_for_an_enabled_key(self):
        wrapper = Path(__file__).with_name("ssh_acp.py").resolve()
        agent = (
            "import json, sys\n"
            "for line in sys.stdin:\n"
            "    packet = json.loads(line)\n"
            "    print(json.dumps({'id': packet['id'], 'result': packet['params']}), flush=True)\n"
        )
        with tempfile.TemporaryDirectory() as workspace:
            socket = str(Path(workspace) / "browser.sock")
            options = ["--safari", socket, "test-riptide-device", "--safari-mcp-python", sys.executable]
            for flags in ([], options):
                with self.subTest(registered=bool(flags)):
                    process = subprocess.Popen(
                        [sys.executable, str(wrapper), "--workspace", workspace,
                         *flags, "--", sys.executable, "-c", agent],
                        env={**os.environ, "SSH_ORIGINAL_COMMAND": "riptide-acp"},
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                    )
                    try:
                        requests = (
                            ("session/new", {"cwd": workspace, "mcpServers": []}),
                            ("session/load", {"cwd": workspace, "sessionId": "main", "mcpServers": []}),
                            ("session/list", {"cwd": workspace}),
                            ("session/new", {"cwd": workspace, "mcpServers": [{"name": "client-provided"}]}),
                        )
                        for request_id, (method, params) in enumerate(requests, 1):
                            process.stdin.write(json.dumps({
                                "jsonrpc": "2.0", "id": request_id, "method": method, "params": params,
                            }) + "\n")
                            process.stdin.flush()
                            self.assertTrue(select.select([process.stdout], [], [], 5)[0], "No ACP reply")
                            reply = json.loads(process.stdout.readline())
                            self.assertEqual(reply["id"], request_id)
                            if request_id == 4:
                                self.assertEqual(reply["error"]["code"], -32602)
                                continue
                            expected = dict(params)
                            if flags and "mcpServers" in expected:
                                expected["mcpServers"] = [{
                                    "name": "riptide_safari", "command": sys.executable,
                                    "args": [str(wrapper.with_name("safari_mcp.py")), "--state-dir", workspace],
                                    "env": [],
                                }]
                            self.assertEqual(reply["result"], expected)
                    finally:
                        process.stdin.close()
                        process.stdout.close()
                        process.wait(timeout=5)
