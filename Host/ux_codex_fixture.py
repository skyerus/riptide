import argparse
import asyncio
import json
import ssl
from http import HTTPStatus
from pathlib import Path

from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed


WORKSPACE = "/riptide-ux-fixture"
CHAT = "busy-fixture-thread"
TURN = "busy-fixture-turn"
TOKEN = "fixture-" + "x" * 40
MODELS = [
    {"model": "gpt-6.2-sol", "displayName": "GPT-6.2 Sol", "defaultReasoningEffort": "xhigh",
     "supportedReasoningEfforts": [{"reasoningEffort": value} for value in ("medium", "high", "xhigh", "ultra")],
     "serviceTiers": [{"id": "priority", "name": "Fast"}]},
    {"model": "gpt-6.2-astra", "displayName": "GPT-6.2 Astra", "defaultReasoningEffort": "medium",
     "supportedReasoningEfforts": [{"reasoningEffort": value} for value in ("medium", "high")]},
]


async def fixture(socket, watch=False):
    async def send(body):
        await socket.send(json.dumps(body))

    async def notify(method, params):
        await send({"method": method, "params": {"threadId": CHAT, **params}})

    async def notify_usage():
        await notify("thread/tokenUsage/updated", {"turnId": TURN, "tokenUsage": {
            "last": {"totalTokens": 8_000}, "modelContextWindow": 32_000,
        }})

    async def conclude(text):
        nonlocal started
        await notify("item/completed", {"turnId": TURN, "item": {
            "id": "fixture-reply", "type": "agentMessage", "text": text,
        }})
        await notify("turn/completed", {"turn": {"id": TURN, "status": "completed"}})
        started = False

    async def continue_turn(needs_approval):
        try:
            await asyncio.sleep(6)
            if needs_approval:
                await send({"id": "fixture-approval", "method": "item/commandExecution/requestApproval", "params": {
                    "threadId": CHAT, "turnId": TURN, "itemId": "fixture-tool", "command": "echo fixture",
                    "availableDecisions": ["accept", "decline"],
                }})
            else:
                await conclude("A reply finished in the other workspace.")
        except ConnectionClosed:
            return

    async def show_live_feedback():
        try:
            await asyncio.sleep(6)
            steps = [{"step": "Inspect the fixture workspace", "status": "inProgress"},
                     {"step": "Summarize the changes", "status": "pending"}]
            await notify("turn/plan/updated", {"turnId": TURN, "plan": steps})
            command = {"id": "fixture-tool", "type": "commandExecution", "command": "git status --short"}
            await notify("item/started", {"turnId": TURN, "item": command})
            await notify("item/commandExecution/outputDelta", {
                "turnId": TURN, "itemId": command["id"], "delta": "Fixture output is ready.",
            })
            await notify("item/completed", {"turnId": TURN, "item": {
                "id": "fixture-note", "type": "agentMessage", "phase": "commentary", "text": "Checking the current changes.",
            }})
            await notify("turn/diff/updated", {"turnId": TURN, "diff": "--- a/demo.txt\n+++ b/demo.txt\n@@ -1 +1 @@\n-old\n+new\n"})
            await asyncio.sleep(12)
            await notify("item/completed", {"turnId": TURN, "item": {**command, "status": "completed", "exitCode": 0}})
            await notify("turn/plan/updated", {"turnId": TURN, "plan": [{**step, "status": "completed"} for step in steps]})
            await conclude("The fixture turn is complete.")
        except ConnectionClosed:
            return

    thread = {"id": CHAT, "name": "Busy Codex fixture", "cwd": WORKSPACE, "status": {"type": "active" if watch else "idle"}}
    thread_settings = {"model": "gpt-6.2-sol", "effort": "xhigh", "serviceTier": None}
    approval = None
    started = False
    try:
        async for raw in socket:
            packet = json.loads(raw)
            method, request = packet.get("method"), packet.get("id")
            if method == "initialized":
                continue
            if method is None and request == "fixture-approval" and started:
                if packet.get("result", {}).get("decision") != "decline":
                    continue
                await notify("serverRequest/resolved", {"requestId": request})
                await conclude("This reply survived switching workspaces.")
                continue
            if method == "initialize":
                result = {}
            elif method == "account/read":
                result = {"account": {"type": "chatgpt"}, "workspaceRouting": {"chatgptAccountId": "fixture-identity"}}
            elif method == "thread/list":
                result = {"data": [thread]}
            elif method == "thread/read":
                result = {"thread": thread}
            elif method == "thread/resume":
                result = {"thread": thread, **thread_settings}
            elif method == "model/list":
                result = {"data": MODELS}
            elif method == "thread/settings/update":
                params = packet.get("params", {})
                options = {key: value for key, value in params.items() if key != "threadId"}
                model = next((row for row in MODELS if row["model"] == options.get("model", thread_settings["model"])), None)
                if (params.get("threadId") != CHAT or not model or options.keys() - thread_settings.keys() or
                        "effort" in options and {"reasoningEffort": options["effort"]} not in model["supportedReasoningEfforts"] or
                        "serviceTier" in options and options["serviceTier"] not in ("priority", "default")):
                    await send({"id": request, "error": {"code": -32602, "message": "Invalid fixture settings."}})
                    continue
                thread_settings.update(options)
                await notify("thread/settings/updated", {"threadSettings": thread_settings})
                result = {}
            elif method == "thread/turns/list":
                result = {"data": [{"id": TURN, "status": "inProgress"}] if watch else []}
                if watch:
                    await notify_usage()
            elif method == "turn/start":
                started = True
                result = {"turn": {"id": TURN}}
                await notify("turn/started", {"turn": {"id": TURN}})
                await notify_usage()
                inputs = packet.get("params", {}).get("input", [])
                await notify("item/completed", {"turnId": TURN, "item": {
                    "id": "fixture-user-message", "type": "userMessage", "content": inputs,
                }})
                feedback = any("show live feedback" in item.get("text", "") for item in inputs)
                needs_approval = not any("finish without approval" in item.get("text", "") for item in inputs)
                approval = asyncio.create_task(show_live_feedback() if feedback else continue_turn(needs_approval))
            else:
                await send({"id": request, "error": {"code": -32601, "message": "Not available in the UX fixture."}})
                continue
            await send({"id": request, "result": result})
    except ConnectionClosed:
        pass
    finally:
        if approval is not None:
            approval.cancel()


async def run(port_file, tls=None, watch=False):
    def authenticate(connection, request):
        if request.headers.get("Authorization") != f"Bearer {TOKEN}":
            return connection.respond(HTTPStatus.UNAUTHORIZED, "Fixture credential required.\n")

    async def handler(socket):
        await fixture(socket, watch)

    async with serve(handler, "127.0.0.1", 0, process_request=authenticate, ssl=tls) as service:
        port_file.write_text(str(service.sockets[0].getsockname()[1]), encoding="utf-8")
        await service.serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Loopback-only App Server fixture for Riptide UI tests.")
    parser.add_argument("--port-file", required=True, type=Path)
    parser.add_argument("--tls-cert", type=Path)
    parser.add_argument("--tls-key", type=Path)
    parser.add_argument("--watch", action="store_true", help="Report an active desktop turn with token usage.")
    args = parser.parse_args()
    if bool(args.tls_cert) != bool(args.tls_key):
        parser.error("--tls-cert and --tls-key must be used together")
    tls = None
    if args.tls_cert:
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(args.tls_cert, args.tls_key)
    asyncio.run(run(args.port_file, tls, args.watch))
