import argparse
import asyncio
import json
import uuid
from urllib.parse import urlsplit

from websockets.asyncio.client import connect

from attention_relay import read_secret, reply_preview, token_from


def safe_origin(value, *, socket=False):
    url = urlsplit(value)
    secure, local = ("wss", "ws") if socket else ("https", "http")
    if (not url.hostname or url.username or url.password or url.query or url.fragment
            or (not socket and url.path not in ("", "/"))
            or not (url.scheme == secure or (url.scheme == local and url.hostname == "127.0.0.1"))):
        raise ValueError("Use private TLS or an explicit loopback endpoint.")
    return value if socket else value.rstrip("/")


class AppServer:
    def __init__(self, socket):
        self.socket = socket
        self.request_id = 0

    async def call(self, method, params):
        self.request_id += 1
        await self.socket.send(json.dumps({"id": self.request_id, "method": method, "params": params}))
        async with asyncio.timeout(8):
            while True:
                packet = json.loads(await self.socket.recv())
                if packet.get("id") != self.request_id or "method" in packet:
                    continue
                if "result" in packet:
                    return packet["result"]
                raise RuntimeError("The App Server refused a read-only request.")

    async def initialize(self):
        await self.call("initialize", {
            "clientInfo": {"name": "riptide-attention", "version": "0.1"},
            "capabilities": {"experimentalApi": True}
        })
        await self.socket.send(json.dumps({"method": "initialized"}))

    async def list_status(self, workspace, account_id):
        account = await self.call("account/read", {"refreshToken": False})
        if ((account.get("account") or {}).get("type") != "chatgpt"
                or (account.get("workspaceRouting") or {}).get("chatgptAccountId") != account_id):
            raise RuntimeError("Codex signed-in account does not match the configured account.")
        result = await self.call("thread/list", {
            "cwd": workspace, "currentAccountOnly": True, "limit": 50, "sortKey": "updated_at"
        })
        statuses = {}
        for chat in result.get("data", []):
            if chat.get("cwd") != workspace or not isinstance(chat.get("id"), str):
                continue
            status = chat.get("status", {})
            kind = status.get("type")
            flags = status.get("activeFlags") or []
            if kind == "active":
                kind = ("approval" if "waitingOnApproval" in flags
                        else "input" if "waitingOnUserInput" in flags else "active")
            statuses[chat["id"]] = (kind, chat.get("updatedAt"))
        return statuses

    async def latest_reply(self, chat):
        latest = await self.call("thread/turns/list", {
            "threadId": chat, "limit": 1, "itemsView": "full", "sortDirection": "desc"
        })
        turns = latest.get("data", [])
        if not turns or turns[0].get("status") != "completed":
            return None
        replies = [item for item in turns[0].get("items", [])
                   if item.get("type") == "agentMessage" and item.get("phase") != "commentary"
                   and isinstance(item.get("text"), str) and item["text"]]
        if not replies:
            return None
        reply = next((item for item in replies if item.get("phase") == "final_answer"), replies[0])
        return reply["text"]


def transitions(before, after):
    for chat, (kind, stamp) in after.items():
        old = before.get(chat, (None, None))[0]
        for reason in ("approval", "input"):
            if kind == reason and old != reason:
                yield chat, reason, "active", stamp
            elif old == reason and kind in ("idle", "active", "approval", "input") and kind != reason:
                yield chat, reason, "resolved", stamp
        if kind == "idle" and old in ("active", "approval", "input"):
            yield chat, "reply", "active", stamp
        elif old == "idle" and kind in ("active", "approval", "input"):
            yield chat, "reply", "resolved", stamp


def enqueue(pending, event):
    key = (event["workspace"], event["chat"], event["reason"], event["eventID"])
    pending[key] = event
    while len(pending) > 100:
        pending.pop(next(iter(pending)))


async def watch(args):
    import httpx

    endpoint = safe_origin(args.app_server, socket=True)
    relay = safe_origin(args.relay)
    bearer = token_from(args.bearer_file)
    publisher = token_from(args.publisher_token_file)
    account_id = read_secret(args.account_id_file)
    if not account_id or not args.cwd.startswith("/"):
        raise ValueError("Supply an account ID file and an absolute Codex workspace.")
    statuses, pending, active_receipts = {}, {}, {}
    async with httpx.AsyncClient(follow_redirects=False, trust_env=False, timeout=5) as client:
        while True:
            try:
                async with connect(endpoint, additional_headers={"Authorization": f"Bearer {bearer}"}, proxy=None,
                                   open_timeout=8, max_size=4 * 1024 * 1024) as socket:
                    server = AppServer(socket)
                    await server.initialize()
                    updated = await server.list_status(args.cwd, account_id)
                    eligible = []
                    for chat, reason, state, stamp in transitions(statuses, updated):
                        preview = None
                        if reason == "reply" and state == "active":
                            reply = await server.latest_reply(chat)
                            if reply is None:
                                continue
                            preview = reply_preview(reply)
                        eligible.append((chat, reason, state, stamp, preview))
                for chat, reason, state, stamp, preview in eligible:
                    key = (chat, reason)
                    if state == "active":
                        receipt = f"codex:{stamp if isinstance(stamp, int) else 0}:{uuid.uuid4()}"
                        active_receipts[key] = receipt
                    else:
                        receipt = active_receipts.pop(key, None)
                        if receipt is None:
                            continue
                    enqueue(pending, {"workspace": args.agent, "chat": chat,
                                      "reason": reason, "state": state, "eventID": receipt, "preview": preview})
                statuses = updated
                while pending:
                    key = next(iter(pending))
                    response = await client.post(relay + "/v1/events", json=pending[key],
                                                 headers={"Authorization": f"Bearer {publisher}"})
                    if response.status_code in (401, 403):
                        raise RuntimeError("The relay rejected the publisher credential.")
                    if response.status_code == 400:
                        pending.pop(key)
                        continue
                    response.raise_for_status()
                    pending.pop(key)
            except RuntimeError:
                raise
            except Exception as error:
                print(f"Attention check deferred ({type(error).__name__}).", flush=True)
            await asyncio.sleep(8)


def main():
    parser = argparse.ArgumentParser(description="Read-only Codex status publisher for Riptide attention.")
    parser.add_argument("--app-server", required=True)
    parser.add_argument("--bearer-file", required=True)
    parser.add_argument("--account-id-file", required=True)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--agent", required=True)
    parser.add_argument("--relay", required=True)
    parser.add_argument("--publisher-token-file", required=True)
    try:
        asyncio.run(watch(parser.parse_args()))
    except (RuntimeError, ValueError) as error:
        parser.exit(2, str(error) + "\n")
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
