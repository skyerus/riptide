"""Private relay for an explicitly shared Safari tab and a local MCP client."""

import argparse
from dataclasses import dataclass
import fcntl
import hashlib
from http import HTTPStatus
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import socket
from socketserver import ThreadingUnixStreamServer
from threading import Condition, Thread
from time import monotonic
from urllib.parse import urlsplit

DEFAULT_STATE = Path.home() / ".local" / "state" / "riptide-safari"
PREFIX = "/v1/safari/"
MAX_BODY = 96 * 1024
PAIR_SECONDS = 600
REQUEST_SECONDS = 300
SHARE_SECONDS = 900
OFFLINE_SECONDS = 25
COMMAND_SECONDS = 25


class RelayError(Exception):
    def __init__(self, message, status=HTTPStatus.CONFLICT):
        super().__init__(message)
        self.status = status


def https_origin(url):
    if (not isinstance(url, str) or len(url) > 2048
            or re.search(r"[\x00-\x20\x7f\\]", url)):
        raise RelayError("Use a valid HTTPS address.", HTTPStatus.BAD_REQUEST)
    try:
        parts = urlsplit(url)
        host, port = parts.hostname, parts.port
    except ValueError as exc:
        raise RelayError("Use a valid HTTPS address.", HTTPStatus.BAD_REQUEST) from exc
    if (parts.scheme != "https" or not host or parts.username is not None
            or not re.fullmatch(r"[a-z0-9.-]+", host) or parts.netloc.endswith(":")):
        raise RelayError("Use an HTTPS hostname without credentials.", HTTPStatus.BAD_REQUEST)
    return f"https://{host}" + (f":{port}" if port not in (None, 443) else "")


def digest(token):
    return hashlib.sha256(token.encode()).hexdigest()


@dataclass
class Command:
    id: str
    action: dict
    delivered: bool = False
    result: dict | None = None


@dataclass
class Handoff:
    id: str
    url: str
    origin: str
    expires_at: float
    active: bool = False
    seen_at: float = 0
    command: Command | None = None
    last_result_id: str | None = None


class Relay:
    def __init__(self, device_file, clock=monotonic):
        self.device_file = device_file
        self.clock = clock
        self.changed = Condition()
        self.handoff = None
        self.pair_code = None
        self.pair_expires_at = 0
        self.device_digest = device_file.read_text().strip() if device_file.exists() else ""

    def clear(self):
        self.handoff = None
        self.changed.notify_all()

    def current(self):
        handoff = self.handoff
        if handoff and (handoff.expires_at <= self.clock() or (
                handoff.active and handoff.seen_at + OFFLINE_SECONDS <= self.clock())):
            self.clear()
        return self.handoff

    def require(self, request_id, *, active=False):
        handoff = self.current()
        if handoff is None or handoff.id != request_id:
            raise RelayError("That handoff ended. Request a new one.")
        if active and not handoff.active:
            raise RelayError("Waiting for you to hand back the tab in Safari.")
        return handoff

    def save_device(self, token):
        next_digest = digest(token) if token else ""
        temporary = self.device_file.with_suffix(".tmp")
        with os.fdopen(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as stream:
            stream.write(next_digest)
        temporary.replace(self.device_file)
        self.device_digest = next_digest

    def browser(self, operation, body, token):
        with self.changed:
            if operation == "pair":
                if (self.pair_code is None or self.clock() >= self.pair_expires_at
                        or not secrets.compare_digest(token, self.pair_code)):
                    raise RelayError("That pairing code is invalid or expired.", HTTPStatus.UNAUTHORIZED)
                device_token = secrets.token_urlsafe(32)
                self.save_device(device_token)
                self.pair_code = None
                self.clear()
                return {"token": device_token}

            if not self.device_digest or not secrets.compare_digest(digest(token), self.device_digest):
                raise RelayError("Pair Riptide Safari with this agent again.", HTTPStatus.UNAUTHORIZED)
            if operation == "forget":
                self.save_device(None)
                self.clear()
                return {}
            if operation == "state":
                handoff = self.current()
                if handoff is None:
                    return {}
                return {"handoff": {"id": handoff.id, "url": handoff.url,
                                    "origin": handoff.origin, "active": handoff.active}}

            handoff = self.require(body.get("id"))
            if operation == "release":
                self.clear()
                return {}
            if body.get("origin") != handoff.origin:
                raise RelayError("The handoff is for a different website.", HTTPStatus.FORBIDDEN)
            if operation == "grant":
                if handoff.active:
                    raise RelayError("A Safari tab is already shared.")
                handoff.active = True
                handoff.seen_at = self.clock()
                handoff.expires_at = self.clock() + SHARE_SECONDS
                self.changed.notify_all()
                return {}
            if not handoff.active:
                raise RelayError("Waiting for the user to share their Safari tab.")
            handoff.seen_at = self.clock()
            command = handoff.command
            if operation == "next":
                if command is None or command.delivered:
                    return {}
                command.delivered = True
                return {"command": {"id": command.id, **command.action}}
            if operation == "result":
                result = body.get("result")
                if not isinstance(result, dict):
                    raise RelayError("Invalid Safari response.", HTTPStatus.BAD_REQUEST)
                if command and command.delivered and command.id == body.get("commandID"):
                    if command.result is None:
                        command.result = result
                        handoff.last_result_id = command.id
                        self.changed.notify_all()
                    return {"accepted": True}
                return {"accepted": handoff.last_result_id is not None
                        and handoff.last_result_id == body.get("commandID")}
            raise RelayError("Unknown Safari operation.", HTTPStatus.NOT_FOUND)

    def agent(self, operation, body):
        with self.changed:
            if operation == "pair":
                self.pair_code = secrets.token_urlsafe(32)
                self.pair_expires_at = self.clock() + PAIR_SECONDS
                return {"code": self.pair_code}
            if operation == "unpair":
                self.pair_code = None
                self.save_device(None)
                self.clear()
                return {}
            if operation == "request":
                origin = https_origin(body.get("url"))
                if self.current() is not None:
                    raise RelayError("A Safari handoff is already pending or active on this relay.")
                handoff = Handoff(secrets.token_urlsafe(18), body["url"], origin, self.clock() + REQUEST_SECONDS)
                self.handoff = handoff
                return {"request_id": handoff.id, "url": handoff.url, "origin": origin,
                        "message": "Open this address in Safari, sign in, then open the Riptide extension and tap Hand back."}

            handoff = self.require(body.get("request_id"))
            if operation == "finish":
                self.clear()
                return {"state": "finished"}
            if operation == "wait":
                seconds = body.get("timeout", 60)
                if type(seconds) is not int or not 1 <= seconds <= 75:
                    raise RelayError("Use a wait timeout from 1 to 75 seconds.", HTTPStatus.BAD_REQUEST)
                deadline = min(handoff.expires_at, self.clock() + seconds)
                while not handoff.active and self.clock() < deadline:
                    self.changed.wait(max(0, deadline - self.clock()))
                    self.require(handoff.id)
                return {"state": "shared" if handoff.active else "waiting", "origin": handoff.origin}
            if operation != "action":
                raise RelayError("Unknown agent operation.", HTTPStatus.NOT_FOUND)
            self.require(handoff.id, active=True)
            if handoff.command is not None:
                raise RelayError("A browser action is already running. Wait for it to finish.")
            command = Command(secrets.token_urlsafe(12), self.action(body, handoff.origin))
            handoff.command = command
            deadline = min(handoff.expires_at, self.clock() + COMMAND_SECONDS)
            try:
                while command.result is None and self.clock() < deadline:
                    self.changed.wait(max(0, deadline - self.clock()))
                    self.require(handoff.id, active=True)
                if command.result is None:
                    raise RelayError("Safari did not confirm the action. Inspect the tab before retrying.")
                return command.result
            finally:
                handoff.command = None

    @staticmethod
    def action(body, origin):
        kind = body.get("kind")
        if kind == "snapshot":
            return {"kind": kind}
        if kind in ("click", "fill", "read_value"):
            ref = body.get("ref")
            if not isinstance(ref, str) or not re.fullmatch(r"[a-f0-9-]{36}:\d{1,3}", ref):
                raise RelayError("Use an element reference from a fresh snapshot.", HTTPStatus.BAD_REQUEST)
            action = {"kind": kind, "ref": ref}
            if kind == "fill":
                value = body.get("value")
                if not isinstance(value, str) or len(value) > 4096:
                    raise RelayError("The field value is too long or invalid.", HTTPStatus.BAD_REQUEST)
                action["value"] = value
            return action
        if kind == "navigate" and https_origin(body.get("url")) == origin:
            return {"kind": kind, "url": body["url"]}
        raise RelayError("Use a supported action within the shared website.", HTTPStatus.BAD_REQUEST)


class Handler(BaseHTTPRequestHandler):
    operations = frozenset()

    def setup(self):
        self.request.settimeout(8)
        super().setup()

    def log_message(self, *_args):
        pass

    def do_POST(self):
        operation = self.path[len(PREFIX):] if self.path.startswith(PREFIX) else ""
        if operation not in self.operations:
            self.respond(HTTPStatus.NOT_FOUND, {"error": "Unknown operation."})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= MAX_BODY:
                raise RelayError("Invalid request size.", HTTPStatus.BAD_REQUEST)
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict):
                raise RelayError("Expected a JSON object.", HTTPStatus.BAD_REQUEST)
            self.respond(HTTPStatus.OK, self.dispatch(operation, body))
        except RelayError as exc:
            self.respond(exc.status, {"error": str(exc)})
        except (ValueError, UnicodeError):
            self.respond(HTTPStatus.BAD_REQUEST, {"error": "Invalid JSON request."})
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass

    def respond(self, status, response):
        data = json.dumps(response, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class BrowserHandler(Handler):
    operations = frozenset(("pair", "state", "grant", "next", "result", "release", "forget"))

    def dispatch(self, operation, body):
        prefix, _, token = self.headers.get("Authorization", "").partition(" ")
        if prefix.lower() != "bearer" or not re.fullmatch(r"[A-Za-z0-9_-]{43}", token):
            raise RelayError("Safari pairing is required.", HTTPStatus.UNAUTHORIZED)
        return self.server.relay.browser(operation, body, token)


class AgentHandler(Handler):
    operations = frozenset(("pair", "unpair", "request", "wait", "action", "finish"))

    def dispatch(self, operation, body):
        return self.server.relay.agent(operation, body)


class AgentServer(ThreadingUnixStreamServer):
    daemon_threads = True


class LocalConnection(HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=85)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(self.timeout)
        self.sock.connect(str(self.path))


def agent_call(state_dir, operation, **body):
    connection = LocalConnection(state_dir / "agent.sock")
    try:
        connection.request("POST", PREFIX + operation, json.dumps(body),
                           {"Content-Type": "application/json"})
        response = connection.getresponse()
        result = json.loads(response.read(MAX_BODY + 1))
        if response.status != HTTPStatus.OK:
            raise RelayError(result.get("error", "Safari bridge error."), response.status)
        return result
    except OSError as exc:
        raise RelayError("The local Riptide Safari relay is unavailable.") from exc
    finally:
        connection.close()


def serve(state_dir, port):
    state_dir.mkdir(mode=0o700, exist_ok=True, parents=True)
    info = state_dir.stat()
    if state_dir.is_symlink() or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise SystemExit("Use a Safari relay state directory owned by this user with mode 0700.")
    with (state_dir / "relay.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise SystemExit("A Safari relay is already running in that state directory.") from exc
        socket_path = state_dir / "agent.sock"
        socket_path.unlink(missing_ok=True)
        relay = Relay(state_dir / "device.sha256")
        with ThreadingHTTPServer(("127.0.0.1", port), BrowserHandler) as browser:
            with AgentServer(str(socket_path), AgentHandler) as agent:
                socket_path.chmod(0o600)
                browser.relay = agent.relay = relay
                thread = Thread(target=agent.serve_forever, daemon=True)
                thread.start()
                try:
                    browser.serve_forever()
                except KeyboardInterrupt:
                    pass
                finally:
                    agent.shutdown()
                    thread.join()
                    socket_path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, default=DEFAULT_STATE)
    subparsers = parser.add_subparsers(dest="command", required=True)
    serve_parser = subparsers.add_parser("serve")
    serve_parser.add_argument("--port", type=int, default=8772)
    subparsers.add_parser("unpair", help="Revoke the paired Safari device")
    pair_parser = subparsers.add_parser("pair")
    pair_parser.add_argument("endpoint", help="Private HTTPS origin or reverse-proxy base path")
    args = parser.parse_args()
    if args.command == "serve":
        serve(args.state_dir, args.port)
        return
    try:
        if args.command == "unpair":
            agent_call(args.state_dir, "unpair")
            return
        https_origin(args.endpoint)
        parts = urlsplit(args.endpoint)
        if parts.query or parts.fragment:
            raise RelayError("The relay endpoint must have no query or fragment.")
        code = agent_call(args.state_dir, "pair")["code"]
        print(f"{args.endpoint.rstrip('/')}#{code}")
    except RelayError as exc:
        raise SystemExit(str(exc)) from exc


if __name__ == "__main__":
    main()
