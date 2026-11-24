import unittest

from ssh_acp import admitted


class SSHACPPolicyTests(unittest.TestCase):
    def test_known_session_methods_and_permission_answers(self):
        workspace = "/agent/workspace"
        for method, params in (
            ("initialize", {"protocolVersion": 1, "clientCapabilities": {}}),
            ("session/list", {}),
            ("session/new", {"cwd": workspace, "mcpServers": []}),
            ("session/load", {"cwd": workspace, "sessionId": "main", "mcpServers": []}),
            ("session/prompt", {"sessionId": "main", "prompt": [{"type": "text", "text": "Hello"}]}),
            ("session/set_config_option", {"sessionId": "main", "configId": "model", "value": "default"}),
        ):
            with self.subTest(method=method):
                self.assertTrue(admitted({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}, workspace, set()))
        pending = {2}
        response = {"jsonrpc": "2.0", "id": 2, "result": {"outcome": {"outcome": "cancelled"}}}
        self.assertTrue(admitted(response, workspace, pending))
        self.assertFalse(admitted(response, workspace, pending))

    def test_cannot_request_extra_capabilities_or_bypass_workspace(self):
        workspace = "/agent/workspace"
        for method, params in (
            ("initialize", {"protocolVersion": 1, "clientCapabilities": {"terminal": True}}),
            ("session/new", {"cwd": workspace, "mcpServers": [{"name": "extra"}]}),
            ("session/load", {"cwd": "/", "sessionId": "main", "mcpServers": []}),
            ("session/load", {"cwd": workspace, "sessionId": "main", "mcpServers": [], "_meta": {}}),
            ("session/set_config_option", {"sessionId": "main", "configId": "mode", "value": "unconfigured"}),
            ("session/prompt", {"sessionId": "main", "prompt": [{"type": "resource", "uri": "file:///example"}]}),
            ("other/method", {}),
        ):
            with self.subTest(method=method):
                self.assertFalse(admitted({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}, workspace, set()))
