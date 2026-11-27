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

from ssh_acp import PRIVATE_FILE_CHUNK, PRIVATE_FILE_GREETING, PRIVATE_FILE_LIMIT, STAGE_ATTACHMENTS, admitted, stage_attachments


class SSHACPPolicyTests(unittest.TestCase):
    def test_browser_handoff_uses_the_shared_owner_for_enabled_members(self):
        wrapper = Path(__file__).with_name("ssh_acp.py").resolve()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            owner = root / "profiles" / "owner"
            member = root / "profiles" / "member"
            owner.mkdir(parents=True)
            member.mkdir()
            manifest = root / "pairing.json"
            manifest.write_text(json.dumps({"chrome": {"home": str(root)}, "targets": {"member": {}}}))
            probe = root / "profile-used"
            hermes = root / "hermes"
            hermes.write_text(f"#!{sys.executable}\nimport os\nfrom pathlib import Path\n"
                              f"Path({str(probe)!r}).write_text(os.environ['HERMES_HOME'])\n")
            hermes.chmod(0o700)
            env = {**os.environ, "SSH_ORIGINAL_COMMAND": "riptide-hermes-screen"}
            browser = ["--hermes-browser-mcp", sys.executable, tmp]
            for membership, opts, expected in (
                ({"members": ["owner", "member"]}, [], member),
                ({"members": ["owner", "member"]}, browser, owner),
                ({"members": ["owner"]}, browser, member),
                ({"members": ["owner"], "pairing_manifest": str(manifest)}, browser, owner),
            ):
                (root / "riptide-shared-browser.json").write_text(json.dumps({"owner": "owner", **membership}))
                argv = [sys.executable, str(wrapper), "--workspace", tmp,
                        "--hermes-screen", str(member), str(hermes), *opts, "--", "/missing-agent"]
                subprocess.run(argv, env=env, input='{"command":"open"}\n',
                               capture_output=True, text=True, timeout=5)
                self.assertEqual(probe.read_text(), str(expected))

    def test_known_session_methods_and_permission_answers(self):
        workspace = "/agent/workspace"
        for method, params in (
            ("initialize", {"protocolVersion": 1, "clientCapabilities": {}}),
            ("initialize", {"protocolVersion": 1, "clientCapabilities": {
                "_meta": {"app.riptide.assistantProgress": True},
            }}),
            ("initialize", {"protocolVersion": 1, "clientCapabilities": {
                "_meta": {"app.riptide.assistantProgress": True, "app.riptide.fastResume": True},
            }}),
            ("session/list", {}),
            ("session/new", {"cwd": workspace, "mcpServers": []}),
            ("session/load", {"cwd": workspace, "sessionId": "main", "mcpServers": []}),
            ("_riptide/session/recent", {"cwd": workspace, "sessionId": "main"}),
            ("_riptide/session/resume", {"cwd": workspace, "sessionId": "main", "mcpServers": [],
                                         "checkpoint": {"rows": 4, "digest": "a" * 64}}),
            ("session/prompt", {"sessionId": "main", "prompt": [{"type": "text", "text": "Hello"}]}),
            ("_riptide/session/steer", {"sessionId": "main", "text": "Focus on the draft"}),
            ("_riptide/session/steer", {"sessionId": "main", "text": "Focus on the draft", "admissionId": "active-admission"}),
            ("session/set_config_option", {"sessionId": "main", "configId": "model", "value": "default"}),
            ("session/set_config_option", {"sessionId": "main", "configId": "service_tier", "value": "fast"}),
            ("session/set_config_option", {"sessionId": "main", "configId": "service_tier", "value": "normal"}),
        ):
            with self.subTest(method=method):
                self.assertTrue(admitted({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}, workspace, set()))
        pending = {2}
        response = {"jsonrpc": "2.0", "id": 2, "result": {"outcome": {"outcome": "cancelled"}}}
        self.assertTrue(admitted(response, workspace, pending))
        self.assertFalse(admitted(response, workspace, pending))

    def test_fast_history_stays_within_the_paired_workspace(self):
        workspace = "/agent/workspace"
        resume = {"cwd": workspace, "sessionId": "main", "mcpServers": []}
        for method, params in (
            ("_riptide/session/recent", {"cwd": "/other", "sessionId": "main"}),
            ("_riptide/session/recent", {"cwd": workspace, "sessionId": "../other"}),
            ("_riptide/session/resume", {**resume, "cwd": "/other"}),
            ("_riptide/session/resume", {**resume, "mcpServers": [{"command": "untrusted"}]}),
            ("_riptide/session/resume", {**resume, "checkpoint": {"rows": True, "digest": "a" * 64}}),
            ("_riptide/session/resume", {**resume, "checkpoint": {"rows": 4, "digest": "bad"}}),
        ):
            with self.subTest(method=method, params=params):
                self.assertFalse(admitted({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}, workspace, set()))

    def test_steering_requires_a_valid_admission_when_supplied(self):
        for admission in (None, 1, "", "x" * 257):
            with self.subTest(admission=admission):
                packet = {"jsonrpc": "2.0", "id": 1, "method": "_riptide/session/steer", "params": {
                    "sessionId": "main", "text": "Follow up", "admissionId": admission,
                }}
                self.assertFalse(admitted(packet, "/agent/workspace", set()))

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

    def test_private_file_uses_the_forced_command_without_starting_the_agent(self):
        wrapper = Path(__file__).with_name("ssh_acp.py").resolve()
        with tempfile.TemporaryDirectory() as workspace:
            argv = [sys.executable, str(wrapper), "--workspace", workspace, "--", "/missing-agent"]
            env = {**os.environ, "SSH_ORIGINAL_COMMAND": "riptide-private-file", "TMPDIR": workspace}
            data = b'{"fixture":"private transfer"}\n'
            request = {"name": "client.json", "dataBase64": base64.b64encode(data).decode()}
            with subprocess.Popen(argv, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True) as upload:
                self.assertTrue(select.select([upload.stdout], [], [], 5)[0], "No private transfer handshake")
                self.assertEqual(json.loads(upload.stdout.readline()), PRIVATE_FILE_GREETING)
                reply, errors = upload.communicate(json.dumps(request) + "\n", timeout=5)
                self.assertEqual(upload.returncode, 0)
                self.assertEqual(errors, "")
            path = Path(json.loads(reply)["path"])
            self.assertEqual(path.parent.parent, Path(workspace))
            self.assertEqual(path.read_bytes(), data)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)

            for malformed in (json.dumps({**request, "name": "../client.json"}) + "\n",
                              json.dumps(request), "x" * (2 * 1024 * 1024) + "\n"):
                attempt = subprocess.run(argv, env=env, input=malformed, capture_output=True,
                                         text=True, check=True, timeout=5)
                self.assertEqual([json.loads(line) for line in attempt.stdout.splitlines()],
                                 [PRIVATE_FILE_GREETING, {"error": "uploadRejected"}])
                self.assertEqual(attempt.stderr, "")
            self.assertEqual(list(Path(workspace).iterdir()), [path.parent])

    def test_streaming_preserves_a_file_larger_than_the_legacy_limit_and_cleans_up_failed_uploads(self):
        wrapper = Path(__file__).with_name("ssh_acp.py").resolve()
        with tempfile.TemporaryDirectory() as workspace:
            argv = [sys.executable, str(wrapper), "--workspace", workspace, "--", "/missing-agent"]
            env = {**os.environ, "SSH_ORIGINAL_COMMAND": "riptide-private-file", "TMPDIR": workspace}
            first = bytes(range(256)) * (PRIVATE_FILE_CHUNK // 256)
            pieces = [first, first, b"tail"]
            data = b"".join(pieces)
            start = {"name": "statement.pdf", "size": len(data)}
            chunks = [{"dataBase64": base64.b64encode(piece).decode()} for piece in pieces]

            def upload(*frames):
                result = subprocess.run(argv, env=env, input="".join(json.dumps(frame) + "\n" for frame in frames),
                                        capture_output=True, text=True, check=True, timeout=6)
                self.assertEqual(result.stderr, "")
                replies = [json.loads(line) for line in result.stdout.splitlines()]
                self.assertEqual(replies.pop(0), PRIVATE_FILE_GREETING)
                return replies

            *progress, receipt = upload(start, *chunks, {"complete": True})
            self.assertEqual(progress, [{"received": value} for value in [0, len(first), 2 * len(first), len(data)]])
            path = Path(receipt["path"])
            self.assertEqual(path.read_bytes(), data)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)

            for frames in (
                ({**start, "size": PRIVATE_FILE_LIMIT + 1},),
                ({**start, "size": True},),
                (start, chunks[0]),
                ({**start, "size": 1}, chunks[0]),
                (start, *chunks, {"complete": False}),
            ):
                self.assertEqual(upload(*frames)[-1], {"error": "uploadRejected"})
                self.assertEqual(list(Path(workspace).iterdir()), [path.parent])

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
            ("initialize", {"protocolVersion": 1, "clientCapabilities": {
                "_meta": {"app.riptide.assistantProgress": True}, "terminal": True,
            }}),
            ("initialize", {"protocolVersion": 1, "clientCapabilities": {
                "_meta": {"app.riptide.assistantProgress": True, "unknown": True},
            }}),
            ("initialize", {"protocolVersion": 1, "clientCapabilities": {
                "_meta": {"app.riptide.assistantProgress": 1},
            }}),
            ("initialize", {"protocolVersion": 1, "clientCapabilities": {
                "_meta": {"app.riptide.assistantProgress": True, "app.riptide.fastResume": 1},
            }}),
            ("session/new", {"cwd": workspace, "mcpServers": [{"name": "extra"}]}),
            ("session/load", {"cwd": "/", "sessionId": "main", "mcpServers": []}),
            ("session/load", {"cwd": workspace, "sessionId": "main", "mcpServers": [], "_meta": {}}),
            ("session/set_config_option", {"sessionId": "main", "configId": "mode", "value": "unconfigured"}),
            ("session/set_config_option", {"sessionId": "main", "configId": "service_tier", "value": "--global"}),
            ("session/prompt", {"sessionId": "main", "prompt": [{"type": "resource", "uri": "file:///example"}]}),
            ("_riptide/session/steer", {"sessionId": "main", "text": " ", "cwd": "/"}),
            ("other/method", {}),
        ):
            with self.subTest(method=method):
                self.assertFalse(admitted({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}, workspace, set()))

    def test_chrome_mcp_is_only_injected_into_admitted_sessions_for_an_enabled_key(self):
        wrapper = Path(__file__).with_name("ssh_acp.py").resolve()
        agent = (
            "import json, sys\n"
            "for line in sys.stdin:\n"
            "    packet = json.loads(line)\n"
            "    print(json.dumps({'id': packet['id'], 'result': packet['params']}), flush=True)\n"
        )
        with tempfile.TemporaryDirectory() as workspace:
            options = ["--hermes-screen", workspace, sys.executable,
                       "--hermes-browser-mcp", sys.executable, workspace]
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
                            ("session/set_config_option", {"sessionId": "main", "configId": "service_tier", "value": "fast"}),
                            ("session/set_config_option", {"sessionId": "main", "configId": "service_tier", "value": "normal"}),
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
                                    "name": "riptide_hermes_browser", "command": sys.executable,
                                    "args": [str(wrapper.with_name("hermes_browser_mcp.py")), "--hermes-source", workspace,
                                             "--profile", str(Path(workspace).resolve())],
                                    "env": [],
                                }]
                            self.assertEqual(reply["result"], expected)
                    finally:
                        process.stdin.close()
                        process.stdout.close()
                        process.wait(timeout=5)
