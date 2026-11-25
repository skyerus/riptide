"""Private relay for an explicitly shared Safari tab and a local MCP client."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import fcntl
from http import HTTPStatus
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler
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
REQUEST_SECONDS = 300
SHARE_SECONDS = 900
OFFLINE_SECONDS = 25
COMMAND_SECONDS = 25
CHAT_TURN_SECONDS = 90
BROWSER_OPERATIONS = frozenset(("state", "prepare_chat", "grant", "next", "result", "release"))


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


@dataclass
class Command:
    id: str
    action: dict
    delivered: bool = False
    result: dict | None = None


@dataclass
class ChatTurn:
    token: str
    device: str
    expires_at: float
    confirmed: bool = False


@dataclass
class Handoff:
    id: str
    url: str
    origin: str
    expires_at: float
    owner: str | None = None
    seen_at: float = 0
    command: Command | None = None
    last_result_id: str | None = None
    chat_turn: ChatTurn | None = None

    @property
    def active(self):
        return self.owner is not None


class Relay:
    def __init__(self, clock=monotonic):
        self.clock = clock
        self.changed = Condition()
        self.handoff = None

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

    def current_chat_turn(self, handoff):
        turn = handoff.chat_turn
        return turn if turn and turn.expires_at > self.clock() else None

    def browser(self, operation, body, device):
        with self.changed:
            if operation == "state":
                handoff = self.current()
                if handoff is None:
                    return {}
                if handoff.active and handoff.owner != device:
                    return {"busy": True}
                state = {"id": handoff.id, "url": handoff.url, "origin": handoff.origin, "active": handoff.active}
                turn = self.current_chat_turn(handoff)
                if turn and turn.device == device and turn.confirmed:
                    state["chat_confirmation"] = turn.token
                return {"handoff": state}

            handoff = self.require(body.get("id"))
            if operation == "prepare_chat":
                if handoff.active:
                    raise RelayError("Safari is already shared.")
                token = body.get("token")
                if not isinstance(token, str) or not re.fullmatch(r"(?i)[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}", token):
                    raise RelayError("Invalid chat turn token.", HTTPStatus.BAD_REQUEST)
                turn = self.current_chat_turn(handoff)
                if turn and turn.device != device:
                    raise RelayError("Another device is confirming this handoff.", HTTPStatus.FORBIDDEN)
                handoff.chat_turn = ChatTurn(token, device, self.clock() + CHAT_TURN_SECONDS)
                return {}
            if operation == "grant":
                if handoff.active:
                    raise RelayError("A Safari tab is already shared.")
                if body.get("origin") != handoff.origin:
                    raise RelayError("The handoff is for a different website.", HTTPStatus.FORBIDDEN)
                handoff.owner = device
                handoff.chat_turn = None
                handoff.seen_at = self.clock()
                handoff.expires_at = self.clock() + SHARE_SECONDS
                self.changed.notify_all()
                return {}
            if not handoff.active or handoff.owner != device:
                raise RelayError("This device doesn’t control the Safari handoff.", HTTPStatus.FORBIDDEN)
            if operation == "release":
                self.clear()
                return {}
            if body.get("origin") != handoff.origin:
                raise RelayError("The handoff is for a different website.", HTTPStatus.FORBIDDEN)
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
            if operation == "request":
                origin = https_origin(body.get("url"))
                if self.current() is not None:
                    raise RelayError("A Safari handoff is already pending or active on this relay.")
                handoff = Handoff(secrets.token_urlsafe(18), body["url"], origin, self.clock() + REQUEST_SECONDS)
                self.handoff = handoff
                return {"request_id": handoff.id, "url": handoff.url, "origin": origin,
                        "message": "Open this address in Safari, sign in, and tell the agent when you’re done."}

            handoff = self.require(body.get("request_id"))
            if operation == "finish":
                self.clear()
                return {"state": "finished"}
            if operation == "confirm_chat":
                if handoff.active:
                    return {"state": "shared"}
                turn = self.current_chat_turn(handoff)
                if turn is None:
                    return {"state": "no_chat_turn"}
                turn.confirmed = True
                return {"state": "confirmed"}
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
    operations = BROWSER_OPERATIONS

    def dispatch(self, operation, body):
        device = self.headers.get("Riptide-Device", "")
        if not valid_device(device):
            raise RelayError("The SSH key has no Safari device binding.", HTTPStatus.UNAUTHORIZED)
        return self.server.relay.browser(operation, body, device)


class AgentHandler(Handler):
    operations = frozenset(("request", "confirm_chat", "wait", "action", "finish"))

    def dispatch(self, operation, body):
        return self.server.relay.agent(operation, body)


class RelayServer(ThreadingUnixStreamServer):
    daemon_threads = True


class LocalConnection(HTTPConnection):
    def __init__(self, path, timeout):
        super().__init__("localhost", timeout=timeout)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(self.timeout)
        self.sock.connect(str(self.path))


def valid_device(device):
    return re.fullmatch(r"[A-Za-z0-9_-]{16,96}", device) is not None


def relay_call(socket_path, operation, body, *, timeout, headers=None):
    connection = LocalConnection(socket_path, timeout)
    try:
        connection.request("POST", PREFIX + operation, json.dumps(body, ensure_ascii=False).encode(),
                           {"Content-Type": "application/json", **(headers or {})})
        response = connection.getresponse()
        result = json.loads(response.read(MAX_BODY + 1))
        if response.status != HTTPStatus.OK:
            raise RelayError(result.get("error", "Safari bridge error."), response.status)
        return result
    except OSError as exc:
        raise RelayError("The local Riptide Safari relay is unavailable.", HTTPStatus.SERVICE_UNAVAILABLE) from exc
    finally:
        connection.close()


def agent_call(state_dir, operation, **body):
    return relay_call(state_dir / "agent.sock", operation, body, timeout=85)


def browser_call(socket_path, device, operation, body):
    if operation not in BROWSER_OPERATIONS or not valid_device(device):
        raise RelayError("This operation is outside the paired Safari route.", HTTPStatus.FORBIDDEN)
    return relay_call(socket_path, operation, body, timeout=5, headers={"Riptide-Device": device})


def serve(state_dir):
    state_dir.mkdir(mode=0o700, exist_ok=True, parents=True)
    info = state_dir.stat()
    if state_dir.is_symlink() or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise SystemExit("Use a Safari relay state directory owned by this user with mode 0700.")
    with (state_dir / "relay.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise SystemExit("A Safari relay is already running in that state directory.") from exc

        paths = [state_dir / name for name in ("agent.sock", "browser.sock")]
        relay = Relay()
        for path in paths:
            path.unlink(missing_ok=True)
        try:
            with (RelayServer(str(paths[0]), AgentHandler) as agent,
                  RelayServer(str(paths[1]), BrowserHandler) as browser):
                for path in paths:
                    path.chmod(0o600)
                agent.relay = browser.relay = relay
                thread = Thread(target=agent.serve_forever, daemon=True)
                thread.start()
                try:
                    browser.serve_forever()
                except KeyboardInterrupt:
                    pass
                finally:
                    agent.shutdown()
                    thread.join()
        finally:
            for path in paths:
                path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, default=DEFAULT_STATE)
    parser.add_argument("command", choices=("serve",))
    args = parser.parse_args()
    serve(args.state_dir)


if __name__ == "__main__":
    main()
