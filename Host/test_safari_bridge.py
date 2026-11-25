import concurrent.futures
from http import HTTPStatus
import json
from pathlib import Path
import tempfile
import time
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from safari_bridge import OFFLINE_SECONDS, PREFIX, Relay, RelayError, agent_call, https_origin


class SafariHandoffTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.now = 100
        self.device_file = Path(self.directory.name) / "device.sha256"
        self.relay = Relay(self.device_file, lambda: self.now)
        self.code = self.relay.agent("pair", {})["code"]
        self.token = self.relay.browser("pair", {}, self.code)["token"]

    def request(self):
        request = self.relay.agent("request", {"url": "https://example.test/login"})
        return {"id": request["request_id"], "origin": request["origin"]}

    def test_one_use_pairing_and_revocation(self):
        with self.assertRaises(RelayError):
            self.relay.browser("pair", {}, self.code)
        self.assertNotIn(self.token, self.device_file.read_text())
        self.assertEqual(self.device_file.stat().st_mode & 0o777, 0o600)
        self.assertEqual(Relay(self.device_file).browser("state", {}, self.token), {})
        self.relay.agent("unpair", {})
        with self.assertRaises(RelayError):
            self.relay.browser("state", {}, self.token)

    def test_grant_is_required_and_only_admits_requested_origin(self):
        request = self.request()
        with self.assertRaisesRegex(RelayError, "hand back"):
            self.relay.agent("action", {"request_id": request["id"], "kind": "snapshot"})
        with self.assertRaisesRegex(RelayError, "different website"):
            self.relay.browser("grant", {**request, "origin": "https://lookalike.test"}, self.token)
        self.relay.browser("grant", request, self.token)
        state = self.relay.agent("wait", {"request_id": request["id"]})
        self.assertEqual(state, {"state": "shared", "origin": "https://example.test"})
        with self.assertRaisesRegex(RelayError, "within"):
            self.relay.agent("action", {"request_id": request["id"], "kind": "navigate",
                                        "url": "https://lookalike.test"})
        with self.assertRaisesRegex(RelayError, "already"):
            self.request()

    def test_command_is_delivered_once_and_stale_result_cannot_complete_it(self):
        request = self.request()
        self.relay.browser("grant", request, self.token)
        with concurrent.futures.ThreadPoolExecutor() as pool:
            future = pool.submit(self.relay.agent, "action", {"request_id": request["id"], "kind": "snapshot"})
            for _ in range(100):
                command = self.relay.browser("next", request, self.token).get("command")
                if command:
                    break
                time.sleep(0.01)
            else:
                self.fail("Agent command did not reach Safari.")
            self.assertEqual(command["kind"], "snapshot")
            self.assertEqual(self.relay.browser("next", request, self.token), {})
            stale = {**request, "commandID": "stale", "result": {"text": "Wrong"}}
            self.assertEqual(self.relay.browser("result", stale, self.token), {"accepted": False})
            self.assertFalse(future.done())
            result = {"text": "Signed-in fixture"}
            response = {**request, "commandID": command["id"], "result": result}
            self.assertEqual(self.relay.browser("result", response, self.token), {"accepted": True})
            self.assertEqual(future.result(timeout=1), result)
            self.assertEqual(self.relay.browser("result", response, self.token), {"accepted": True})

    def test_an_offline_tab_expires_and_cannot_rejoin(self):
        request = self.request()
        self.relay.browser("grant", request, self.token)
        self.now += OFFLINE_SECONDS + 1
        self.assertEqual(self.relay.browser("state", {}, self.token), {})
        with self.assertRaisesRegex(RelayError, "ended"):
            self.relay.browser("next", request, self.token)
        self.assertNotEqual(self.request()["id"], request["id"])

    def test_release_invalidates_only_its_own_request(self):
        request = self.request()
        self.relay.browser("grant", request, self.token)
        self.relay.browser("release", request, self.token)
        next_request = self.request()
        with self.assertRaisesRegex(RelayError, "ended"):
            self.relay.browser("release", request, self.token)
        self.assertEqual(self.relay.browser("state", {}, self.token)["handoff"]["id"], next_request["id"])

    def test_only_real_https_origins_are_supported(self):
        self.assertEqual(https_origin("https://EXAMPLE.test:443/path"), "https://example.test")
        for url in ("http://example.test", "https://user@example.test", "https://example.test\\@other.test",
                    "https://example.test:!", "https://example.test\n"):
            with self.subTest(url=url), self.assertRaises(RelayError):
                https_origin(url)


class SafariRelayTransportTests(unittest.TestCase):
    def test_public_socket_has_no_agent_operations_and_requires_browser_token(self):
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary)
            # Port zero asks the kernel for a loopback port. The test discovers it in the same process.
            from http.server import ThreadingHTTPServer
            from threading import Thread
            from safari_bridge import AgentHandler, AgentServer, BrowserHandler

            relay = Relay(state_dir / "device.sha256")
            with (ThreadingHTTPServer(("127.0.0.1", 0), BrowserHandler) as public,
                  AgentServer(str(state_dir / "agent.sock"), AgentHandler) as private):
                public.relay = private.relay = relay
                threads = [Thread(target=server.serve_forever, daemon=True) for server in (public, private)]
                for thread in threads:
                    thread.start()
                try:
                    address = f"http://127.0.0.1:{public.server_port}" + PREFIX

                    def send(operation, token=""):
                        request = Request(address + operation, data=b"{}", headers={"Authorization": f"Bearer {token}"})
                        return json.loads(urlopen(request, timeout=2).read())

                    with self.assertRaises(HTTPError) as error:
                        send("request")
                    self.assertEqual(error.exception.code, HTTPStatus.NOT_FOUND)
                    with self.assertRaises(HTTPError) as error:
                        send("state")
                    self.assertEqual(error.exception.code, HTTPStatus.UNAUTHORIZED)
                    code = agent_call(state_dir, "pair")["code"]
                    token = send("pair", code)["token"]
                    self.assertEqual(send("state", token), {})
                finally:
                    for server in (public, private):
                        server.shutdown()
                    for thread in threads:
                        thread.join()


if __name__ == "__main__":
    unittest.main()
