"""Bind one restricted SSH channel to one local Hermes Talk subscription call."""

from contextlib import suppress
import http.client
import json
import re
import sys
import uuid

from ssh_pairing_files import read_owned


MAX_REQUEST = 128 * 1024
MAX_EVENTS = 2 * 1024 * 1024
ROUTE = "/api/plugins/hermes-talk"
MODELS = ("gpt-live-1-codex", "gpt-live-1-boulder-alpha")


class TalkError(Exception):
    pass


def identifier(value, limit=256):
    return isinstance(value, str) and len(value) <= limit and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", value)


def token(value):
    return isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_.~+/=-]{32,4096}", value)


def sdp(value):
    try:
        return isinstance(value, str) and value.startswith("v=0") and len(value.encode()) <= 65536
    except UnicodeEncodeError:
        return False


class TalkCall:
    def __init__(self, path):
        try:
            data, mode = read_owned(path)
            if not path.is_absolute() or mode != 0o600 or not data or len(data) > 16384:
                raise ValueError
            config = json.loads(data)
            self.port = config["port"]
            self.profile = config["profile"]
            dashboard = config["dashboardToken"]
            talk = config.get("talkToken")
            if (type(self.port) is not int or not 1 <= self.port <= 65535 or
                    not identifier(self.profile, 64) or "." in self.profile or
                    not token(dashboard) or (talk is not None and not token(talk))):
                raise ValueError
        except (OSError, ValueError, KeyError, TypeError) as error:
            raise TalkError("disabled") from error
        self.headers = {"X-Hermes-Session-Token": dashboard, "Content-Type": "application/json"}
        if talk is not None:
            self.headers["X-Talk-Token"] = talk
        self.tab = uuid.uuid4().hex
        self.context = None
        self.binding = None

    def send(self, route, body=None, timeout=5):
        limit = MAX_EVENTS if route == "/live/events" else MAX_REQUEST
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=timeout)
        try:
            connection.request("GET" if body is None else "POST", ROUTE + route,
                               None if body is None else json.dumps(body), self.headers)
            response = connection.getresponse()
            if response.status in (401, 403):
                raise TalkError("authentication")
            if response.status != 200:
                raise TalkError("unavailable")
            raw = response.read(limit + 1)
            if len(raw) > limit:
                raise TalkError("invalidReply")
            result = json.loads(raw)
            if not isinstance(result, dict):
                raise TalkError("invalidReply")
            return result
        except (OSError, http.client.HTTPException) as error:
            raise TalkError("unavailable") from error
        except ValueError as error:
            raise TalkError("invalidReply") from error
        finally:
            connection.close()

    def check_subscription(self):
        status = self.send("/status")
        continuity = status.get("taskContinuity")
        if (status.get("ok") is not True or status.get("configured") is not True or
                status.get("voiceMode") != "live" or status.get("liveAuth") != "subscription" or
                status.get("source") != "codex-oauth" or not isinstance(continuity, dict) or
                continuity.get("supported") is not True or
                status.get("model") not in MODELS):
            raise TalkError("subscription")

    def start(self, session, offer):
        if self.context is not None or not identifier(session) or not sdp(offer):
            raise TalkError("invalidRequest")
        self.check_subscription()
        selection = {"peer_id": "local", "profile": self.profile, "session_id": session}
        catalog = self.send("/targets", {**selection, "tab_id": self.tab})
        targets = catalog.get("targets")
        if catalog.get("ok") is not True or not isinstance(targets, list):
            raise TalkError("wrongChat")
        matches = [item.get("target_id") for item in targets if isinstance(item, dict)
                   and all(item.get(key) == value for key, value in selection.items())]
        if len(matches) != 1 or not identifier(matches[0]):
            raise TalkError("wrongChat")
        target = matches[0]
        attachment = {"tab_id": self.tab, "target_id": target}
        reply = self.send("/native/attach", {**attachment, "input_mode": "typed", "surface": "dashboard"})
        task = reply.get("task")
        if not isinstance(task, dict) or any(task.get(key) != value for key, value in attachment.items()):
            raise TalkError("wrongChat")
        connection, generation = task.get("connection_id"), task.get("generation")
        if not identifier(connection) or type(generation) is not int or generation < 0:
            raise TalkError("wrongChat")
        self.context = {"connection_id": connection, "generation": generation}
        active = reply.get("selection")
        if (reply.get("ok") is not True or reply.get("input_mode") != "typed" or
                not isinstance(active, dict) or active.get("state") != "activated" or
                active.get("target_id") != target or any(task.get(key) != value for key, value in selection.items())):
            raise TalkError("wrongChat")
        self.check_subscription()
        live = self.send("/live/session", {**self.context, "sdp": offer}, timeout=38)
        binding = live.get("binding_id")
        if identifier(binding):
            self.binding = binding
        if live.get("ok") is not True or self.binding is None or not sdp(live.get("sdp")):
            raise TalkError("invalidReply")
        return {"ok": True, "sdp": live["sdp"]}

    def events(self, after):
        if self.binding is None or type(after) is not int or not 0 <= after <= sys.maxsize:
            raise TalkError("invalidRequest")
        reply = self.send("/live/events", {**self.context, "binding_id": self.binding, "after": after})
        events = reply.get("events")
        cursor = reply.get("cursor")
        if (reply.get("ok") is not True or type(cursor) is not int or not 0 <= cursor <= sys.maxsize or
                not isinstance(events, list)):
            raise TalkError("invalidReply")
        result = []
        for event in events:
            if not isinstance(event, dict):
                raise TalkError("invalidReply")
            sequence, kind = event.get("sequence"), event.get("type")
            if type(sequence) is not int or not 0 <= sequence <= sys.maxsize or not isinstance(kind, str):
                raise TalkError("invalidReply")
            state = {"sequence": sequence, "type": kind if kind in ("operation", "result", "error") else "other"}
            if kind == "operation" and type(event.get("pending")) is bool:
                state["pending"] = event["pending"]
            result.append(state)
        return {"ok": True, "cursor": cursor, "events": result}

    def close(self):
        if self.binding is not None:
            with suppress(TalkError):
                self.send("/live/close", {**self.context, "binding_id": self.binding}, timeout=3)
        if self.context is not None:
            with suppress(TalkError):
                self.send("/close", self.context, timeout=3)


def serve(path):
    call = None
    try:
        if path is None:
            raise TalkError("disabled")
        call = TalkCall(path)
        while frame := sys.stdin.buffer.readline(MAX_REQUEST + 1):
            if len(frame) > MAX_REQUEST or not frame.endswith(b"\n"):
                raise TalkError("invalidRequest")
            try:
                request = json.loads(frame)
            except ValueError as error:
                raise TalkError("invalidRequest") from error
            if not isinstance(request, dict):
                raise TalkError("invalidRequest")
            operation = request.get("operation")
            if operation == "start" and request.keys() == {"operation", "sessionID", "sdp"}:
                reply = call.start(request["sessionID"], request["sdp"])
            elif operation == "events" and request.keys() == {"operation", "after"}:
                reply = call.events(request["after"])
            elif operation == "status" and request.keys() == {"operation"} and call.context is None:
                call.check_subscription()
                reply = {"ok": True}
            else:
                raise TalkError("invalidRequest")
            encoded = json.dumps(reply)
            if len(encoded) >= MAX_EVENTS:
                raise TalkError("invalidReply")
            print(encoded, flush=True)
    except TalkError as error:
        with suppress(BrokenPipeError):
            print(json.dumps({"error": str(error)}), flush=True)
    except BrokenPipeError:
        pass
    finally:
        if call is not None:
            call.close()
