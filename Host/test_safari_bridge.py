import concurrent.futures
from http import HTTPStatus
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

from safari_bridge import OFFLINE_SECONDS, Relay, RelayError, agent_call, https_origin


class SafariHandoffTests(unittest.TestCase):
    def setUp(self):
        self.now = 100
        self.relay = Relay(lambda: self.now)
        self.device = "device-first-abcdef"

    def request(self):
        request = self.relay.agent("request", {"url": "https://example.test/login"})
        return {"id": request["request_id"], "origin": request["origin"]}

    def test_another_paired_device_cannot_read_or_revoke_an_active_tab(self):
        request = self.request()
        other = "device-second-abcdef"
        self.relay.browser("grant", request, self.device)
        self.assertEqual(self.relay.browser("state", {}, other), {"busy": True})
        for operation in ("next", "result", "release"):
            with self.subTest(operation=operation), self.assertRaises(RelayError) as error:
                self.relay.browser(operation, request, other)
            self.assertEqual(error.exception.status, HTTPStatus.FORBIDDEN)
        self.assertEqual(self.relay.browser("state", {}, self.device)["handoff"]["id"], request["id"])

    def test_grant_is_required_and_only_admits_requested_origin(self):
        request = self.request()
        with self.assertRaisesRegex(RelayError, "hand back"):
            self.relay.agent("action", {"request_id": request["id"], "kind": "snapshot"})
        with self.assertRaisesRegex(RelayError, "different website"):
            self.relay.browser("grant", {**request, "origin": "https://lookalike.test"}, self.device)
        self.relay.browser("grant", request, self.device)
        state = self.relay.agent("wait", {"request_id": request["id"]})
        self.assertEqual(state, {"state": "shared", "origin": "https://example.test"})
        with self.assertRaisesRegex(RelayError, "within"):
            self.relay.agent("action", {"request_id": request["id"], "kind": "navigate",
                                        "url": "https://lookalike.test"})
        with self.assertRaisesRegex(RelayError, "already"):
            self.request()

    def test_command_is_delivered_once_and_stale_result_cannot_complete_it(self):
        request = self.request()
        self.relay.browser("grant", request, self.device)
        with concurrent.futures.ThreadPoolExecutor() as pool:
            future = pool.submit(self.relay.agent, "action", {"request_id": request["id"], "kind": "snapshot"})
            for _ in range(100):
                command = self.relay.browser("next", request, self.device).get("command")
                if command:
                    break
                time.sleep(0.01)
            else:
                self.fail("Agent command did not reach Safari.")
            self.assertEqual(command["kind"], "snapshot")
            self.assertEqual(self.relay.browser("next", request, self.device), {})
            stale = {**request, "commandID": "stale", "result": {"text": "Wrong"}}
            self.assertEqual(self.relay.browser("result", stale, self.device), {"accepted": False})
            self.assertFalse(future.done())
            result = {"text": "Signed-in fixture"}
            response = {**request, "commandID": command["id"], "result": result}
            self.assertEqual(self.relay.browser("result", response, self.device), {"accepted": True})
            self.assertEqual(future.result(timeout=1), result)
            self.assertEqual(self.relay.browser("result", response, self.device), {"accepted": True})

    def test_an_offline_tab_expires_and_cannot_rejoin(self):
        request = self.request()
        self.relay.browser("grant", request, self.device)
        self.now += OFFLINE_SECONDS + 1
        self.assertEqual(self.relay.browser("state", {}, self.device), {})
        with self.assertRaisesRegex(RelayError, "ended"):
            self.relay.browser("next", request, self.device)
        self.assertNotEqual(self.request()["id"], request["id"])

    def test_release_invalidates_only_its_own_request(self):
        request = self.request()
        self.relay.browser("grant", request, self.device)
        self.relay.browser("release", request, self.device)
        next_request = self.request()
        with self.assertRaisesRegex(RelayError, "ended"):
            self.relay.browser("release", request, self.device)
        self.assertEqual(self.relay.browser("state", {}, self.device)["handoff"]["id"], next_request["id"])

    def test_only_real_https_origins_are_supported(self):
        self.assertEqual(https_origin("https://EXAMPLE.test:443/path"), "https://example.test")
        for url in ("http://example.test", "https://user@example.test", "https://example.test\\@other.test",
                    "https://example.test:!", "https://example.test\n"):
            with self.subTest(url=url), self.assertRaises(RelayError):
                https_origin(url)


class SafariRelayTransportTests(unittest.TestCase):
    def test_forced_ssh_command_uses_the_browser_socket_and_rejects_agent_operations(self):
        host = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary)
            relay = subprocess.Popen([sys.executable, str(host / "safari_bridge.py"),
                                      "--state-dir", str(state_dir), "serve"])
            self.addCleanup(wait_for_exit, relay)
            browser_socket = state_dir / "browser.sock"
            for _ in range(100):
                if browser_socket.is_socket():
                    break
                time.sleep(0.02)
            else:
                self.fail("The Safari relay did not start.")
            self.assertEqual(browser_socket.stat().st_mode & 0o777, 0o600)
            self.assertEqual((state_dir / "agent.sock").stat().st_mode & 0o777, 0o600)

            args = [sys.executable, str(host / "ssh_acp.py"), "--workspace", temporary]
            environment = {**os.environ, "SSH_ORIGINAL_COMMAND": "riptide-safari"}
            missing = subprocess.run(args, env=environment, capture_output=True, check=False, timeout=4)
            self.assertNotEqual(missing.returncode, 0)
            self.assertEqual(json.loads(missing.stdout)["status"], 403)

            request = agent_call(state_dir, "request", url="https://example.test/login")
            denied = {"operation": "request", "body": {"url": "https://other.test"}}
            state = {"operation": "state", "body": {}}
            grant = {"operation": "grant", "body": {"id": request["request_id"], "origin": request["origin"]}}
            inputs = "".join(json.dumps(value) + "\n" for value in (denied, state, grant))
            browser = subprocess.run([*args, "--safari", str(browser_socket), "fixture-device-ssh"],
                                     env=environment, input=inputs, capture_output=True, text=True,
                                     check=True, timeout=4)
            responses = [json.loads(line) for line in browser.stdout.splitlines()]
            self.assertEqual([item["status"] for item in responses], [403, 200, 200])
            self.assertEqual(responses[1]["body"]["handoff"]["id"], request["request_id"])
            self.assertEqual(agent_call(state_dir, "wait", request_id=request["request_id"])["state"], "shared")


def wait_for_exit(process):
    if process.poll() is None:
        process.terminate()
    process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
