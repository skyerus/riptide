import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import stat
import tempfile
import time
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs


MAX_DEVICES = 8
MAX_EVENTS = 250
WORKSPACE_ID = r"[A-Za-z0-9._-]{1,160}"
HOLD_SECONDS = 600
PRESENCE_SECONDS = 45
FOCUS_GRACE_SECONDS = 12
INBOX_SECONDS = 3600
REASONS = {
    "approval": "Approval needed",
    "input": "Waiting for your input",
    "reply": "Reply ready",
}


def read_secret(path):
    file = Path(path)
    permissions = file.stat().st_mode
    if not stat.S_ISREG(permissions) or permissions & 0o077:
        raise ValueError("Credential files must be private regular files (mode 0600).")
    return file.read_text(encoding="utf-8").strip()


def valid(value, pattern):
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def token_from(path):
    value = read_secret(path)
    if not valid(value, r"[A-Za-z0-9_.~+/=-]{32,512}"):
        raise ValueError("Use a long random relay token.")
    return value


def atomic_json(path, contents):
    descriptor, temporary = tempfile.mkstemp(prefix=".riptide-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(contents, stream)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@dataclass(frozen=True)
class AttentionEvent:
    workspace: str
    chat: str
    reason: str
    event_id: str

    @property
    def target(self):
        return (self.workspace, self.chat, self.reason)

    @classmethod
    def parse(cls, body):
        workspace, chat, reason, event_id = (body.get(key) for key in ("workspace", "chat", "reason", "eventID"))
        if (not valid(workspace, WORKSPACE_ID)
                or not valid(chat, r"[A-Za-z0-9._:-]{1,240}")
                or not isinstance(reason, str) or reason not in REASONS
                or not valid(event_id, r"[A-Za-z0-9._:-]{1,160}")):
            raise ValueError("Invalid event identifiers.")
        return cls(workspace, chat, reason, event_id)


class AttentionState:
    def __init__(self, *, send=None, device_file=None, clock=time.time):
        self.send = send
        self.device_file = device_file
        self.clock = clock
        self.presence = {}
        self.devices = {}
        self.pending = {}
        self.seen = {}
        self.inbox = {}
        if device_file and device_file.exists():
            for row in json.loads(read_secret(device_file)).values():
                self.register(row, save=False)

    def report_presence(self, body):
        workspace = body.get("workspace")
        if not valid(workspace, WORKSPACE_ID):
            raise ValueError("Presence must name a paired workspace.")
        if type(body.get("active")) is not bool:
            raise ValueError("Presence must be an explicit boolean.")
        now = self.clock()
        self.presence = {key: row for key, row in self.presence.items() if now - row[0] <= PRESENCE_SECONDS}
        previous = self.presence.get(workspace)
        if previous is None and len(self.presence) >= 100:
            oldest = min(self.presence, key=lambda key: self.presence[key][0])
            self.presence.pop(oldest)
        active = body["active"]
        self.presence[workspace] = (now, active, now if active else (previous[2] if previous else None))

    def effective_presence(self, workspace):
        sample = self.presence.get(workspace)
        now = self.clock()
        if sample is None or not 0 <= now - sample[0] <= PRESENCE_SECONDS:
            return None
        observed, active, last_active = sample
        if not active and last_active is not None and 0 <= now - last_active < FOCUS_GRACE_SECONDS:
            return {"active": True, "observedAt": last_active}
        return {"active": active, "observedAt": observed}

    def latest_presence(self):
        fresh = (self.effective_presence(workspace) for workspace in self.presence)
        return max((sample for sample in fresh if sample is not None),
                   key=lambda sample: (sample["active"], sample["observedAt"]), default=None)

    def register(self, body, *, save=True):
        device, token, environment, policy = (body.get(key) for key in ("id", "token", "environment", "policy"))
        if not valid(device, r"[0-9a-fA-F-]{36}") or environment not in ("development", "production"):
            raise ValueError("Invalid device registration.")
        if not isinstance(policy, dict) or policy.get("delivery") not in ("off", "whenAway", "always"):
            raise ValueError("Invalid alert settings.")
        if not all(type(policy.get(key)) is bool for key in ("approvals", "replies")):
            raise ValueError("Invalid alert settings.")
        if token is None or policy["delivery"] == "off":
            self.remove(device, save=save)
            return
        if not valid(token, r"[0-9a-f]{32,256}") or len(token) % 2 != 0:
            raise ValueError("Invalid device token.")
        if self.send is None:
            raise RuntimeError("APNs is not configured.")
        if device not in self.devices and len(self.devices) >= MAX_DEVICES:
            raise RuntimeError("Device capacity reached.")
        self.devices[device] = {
            "id": device,
            "token": token,
            "environment": environment,
            "policy": {field: policy[field] for field in ("delivery", "approvals", "replies")},
        }
        if save:
            self.persist()

    def remove(self, device, *, save=True):
        if self.devices.pop(device, None) is not None:
            self.pending = {key: value for key, value in self.pending.items() if key[0] != device}
            if save:
                self.persist()

    def persist(self):
        if self.device_file is not None:
            atomic_json(self.device_file, self.devices)

    def publish(self, body):
        event = AttentionEvent.parse(body)
        disposition = body.get("state", "active")
        key = (*event.target, event.event_id)
        now = self.clock()
        if disposition == "resolved":
            self.remember(key, now)
            self.pending = {
                key: item for key, item in self.pending.items()
                if key[1] != event.target or item[0].event_id != event.event_id
            }
            current = self.inbox.get(event.target)
            if current and current[0].event_id == event.event_id:
                self.inbox.pop(event.target)
            return
        if disposition != "active":
            raise ValueError("Invalid activity state.")
        if key in self.seen:
            return
        self.remember(key, now)
        self.inbox[event.target] = (event, now)
        if len(self.inbox) > 100:
            self.inbox.pop(next(iter(self.inbox)))
        for device in self.devices:
            self.pending[(device, event.target)] = (event, now, now, 0)
        while len(self.pending) > MAX_EVENTS:
            self.pending.pop(next(iter(self.pending)))

    def remember(self, key, now):
        self.seen.pop(key, None)
        self.seen[key] = now
        if len(self.seen) > MAX_EVENTS * 2:
            self.seen.pop(next(iter(self.seen)))

    def entries(self):
        now = self.clock()
        self.inbox = {key: row for key, row in self.inbox.items() if 0 <= now - row[1] <= INBOX_SECONDS}
        latest = sorted(self.inbox.values(), key=lambda row: row[1], reverse=True)
        return [{"workspace": event.workspace, "chat": event.chat, "eventID": event.event_id,
                 "reason": event.reason, "observedAt": date} for event, date in latest]

    def flush(self):
        now = self.clock()
        if self.send is None:
            return
        attempted = 0
        for key, entry in list(self.pending.items()):
            if key not in self.pending:
                continue
            device_id, _ = key
            device = self.devices.get(device_id)
            event, created, due, retries = entry
            if not device or now - created > HOLD_SECONDS:
                self.pending.pop(key, None)
                continue
            policy = device["policy"]
            enabled = policy["replies"] if event.reason == "reply" else policy["approvals"]
            if not enabled:
                self.pending.pop(key, None)
                continue
            desktop_active = (self.effective_presence(event.workspace) or {}).get("active", False)
            if due > now or (desktop_active and policy["delivery"] == "whenAway"):
                continue
            attempted += 1
            outcome = self.send(device, event)
            if outcome == "invalid":
                self.remove(device_id)
            elif outcome == "retry" and retries < 3:
                self.pending[key] = (event, created, now + (3 << retries), retries + 1)
            else:
                self.pending.pop(key, None)
            if attempted >= 2:
                break


class APNs:
    def __init__(self, *, team, key_id, topic, key_file):
        import httpx
        from cryptography.hazmat.primitives.serialization import load_pem_private_key
        from cryptography.hazmat.primitives.asymmetric import ec

        if not valid(team, r"[A-Z0-9]{10}") or not valid(key_id, r"[A-Z0-9]{10}") or not valid(topic, r"[A-Za-z0-9.-]{3,180}"):
            raise ValueError("Set a valid Apple team, key ID, and bundle ID.")
        self.key = load_pem_private_key(read_secret(key_file).encode(), password=None)
        if not isinstance(self.key, ec.EllipticCurvePrivateKey) or not isinstance(self.key.curve, ec.SECP256R1):
            raise ValueError("APNs requires an ES256 signing key.")
        self.team, self.key_id, self.topic = team, key_id, topic
        self.authorization = None
        self.created = 0
        self.client = httpx.Client(http2=True, follow_redirects=False, trust_env=False, timeout=4)
        self.network_error = httpx.RequestError

    def bearer(self):
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

        def b64(data):
            return base64.urlsafe_b64encode(data).rstrip(b"=")

        now = int(time.time())
        if self.authorization is None or now - self.created >= 2400:
            headers = json.dumps({"alg": "ES256", "kid": self.key_id}).encode()
            claims = json.dumps({"iss": self.team, "iat": now}).encode()
            body = b".".join((b64(headers), b64(claims)))
            left, right = decode_dss_signature(self.key.sign(body, ec.ECDSA(hashes.SHA256())))
            signature = left.to_bytes(32, "big") + right.to_bytes(32, "big")
            self.authorization = "Bearer " + (body + b"." + b64(signature)).decode("ascii")
            self.created = now
        return self.authorization

    def send(self, device, event):
        host = "api.sandbox.push.apple.com" if device["environment"] == "development" else "api.push.apple.com"
        key = hashlib.sha256("\n".join(event.target).encode()).hexdigest()
        headers = {
            "authorization": self.bearer(),
            "apns-topic": self.topic,
            "apns-push-type": "alert",
            "apns-expiration": str(int(time.time()) + 300),
            "apns-collapse-id": key,
        }
        payload = {
            "aps": {"alert": {"title": "Riptide", "body": REASONS[event.reason]}, "sound": "default"},
            "workspace": event.workspace,
            "chat": event.chat,
        }
        try:
            response = self.client.post(f"https://{host}/3/device/{device['token']}", headers=headers, json=payload)
        except self.network_error:
            return "retry"
        if response.status_code == 200:
            return "sent"
        if response.status_code in (429, 500, 503):
            return "retry"
        try:
            reason = response.json().get("reason")
        except ValueError:
            reason = None
        if response.status_code == 410 or reason in ("BadDeviceToken", "DeviceTokenNotForTopic"):
            return "invalid"
        return "refused"


class Relay(HTTPServer):
    def __init__(self, port, state, client_token, publisher_token):
        self.state, self.client_token, self.publisher_token = state, client_token, publisher_token
        super().__init__(("127.0.0.1", port), Handler)

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(6)
        return connection, address

    def service_actions(self):
        self.state.flush()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def reply(self, code, payload):
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def verify(self, expected):
        headers = self.headers.get_all("Authorization") or []
        allowed = len(headers) == 1 and hmac.compare_digest(headers[0].encode(), f"Bearer {expected}".encode())
        if not allowed:
            self.reply(401, {"ok": False})
        return allowed

    def do_GET(self):
        path, separator, query = self.path.partition("?")
        if path not in ("/v1/presence", "/v1/inbox"):
            self.reply(404, {"ok": False})
            return
        if not self.verify(self.server.client_token):
            return
        if separator:
            try:
                options = parse_qs(query, strict_parsing=True, max_num_fields=1)
                workspace, = options.get("workspace", [])
                if path != "/v1/presence" or not valid(workspace, WORKSPACE_ID):
                    raise ValueError("Invalid presence workspace.")
            except ValueError:
                self.reply(400, {"ok": False})
            else:
                self.reply(200, self.server.state.effective_presence(workspace))
        else:
            self.reply(200, self.server.state.latest_presence() if path == "/v1/presence"
                       else self.server.state.entries())

    def do_POST(self):
        handlers = {
            "/v1/devices": (self.server.client_token, self.server.state.register),
            "/v1/presence": (self.server.publisher_token, self.server.state.report_presence),
            "/v1/events": (self.server.publisher_token, self.server.state.publish),
        }
        chosen = handlers.get(self.path)
        if chosen is None:
            self.reply(404, {"ok": False})
            return
        token, handler = chosen
        if not self.verify(token):
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
            if not 0 < length <= 8192:
                raise ValueError("Invalid request length.")
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict):
                raise ValueError("Expected an object.")
            handler(body)
        except (ValueError, TimeoutError):
            self.reply(400, {"ok": False})
        except (RuntimeError, OSError):
            self.reply(503, {"ok": False})
        else:
            self.reply(200, {"ok": True})


def main():
    parser = argparse.ArgumentParser(description="Single-user desktop presence and optional APNs relay, bound to loopback.")
    parser.add_argument("--port", type=int, default=8766)
    parser.add_argument("--client-token-file", required=True)
    parser.add_argument("--publisher-token-file", required=True)
    parser.add_argument("--device-file", type=Path)
    parser.add_argument("--apns-key-file")
    parser.add_argument("--apns-team")
    parser.add_argument("--apns-key-id")
    parser.add_argument("--apns-topic", default="app.riptide.client")
    args = parser.parse_args()
    client, publisher = token_from(args.client_token_file), token_from(args.publisher_token_file)
    if hmac.compare_digest(client, publisher):
        parser.error("Use different client and publisher credentials.")
    send = None
    if args.apns_key_file:
        if not all((args.apns_team, args.apns_key_id, args.device_file)):
            parser.error("APNs requires a team ID, key ID, and a device state file in a private directory.")
        send = APNs(team=args.apns_team, key_id=args.apns_key_id, topic=args.apns_topic, key_file=args.apns_key_file).send
    if args.device_file and args.device_file.parent.stat().st_mode & 0o077:
        parser.error("The device state directory must be private (mode 0700).")
    state = AttentionState(device_file=args.device_file, send=send)
    with Relay(args.port, state, client, publisher) as relay:
        print(f"Attention relay on 127.0.0.1:{relay.server_port}", flush=True)
        relay.serve_forever(poll_interval=1)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
