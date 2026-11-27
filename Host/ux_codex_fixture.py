import argparse
import asyncio
from functools import partial
import json
import ssl
import time
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


async def fixture(socket, live=False, watch_progress=False, compaction=False, voice=False):
    async def send(body):
        await socket.send(json.dumps(body))

    async def notify(method, params):
        await send({"method": method, "params": {"threadId": CHAT, **params}})

    async def notify_usage():
        await notify("thread/tokenUsage/updated", {"turnId": turn_id, "tokenUsage": {
            "last": {"totalTokens": 8_000}, "modelContextWindow": 32_000,
        }})

    files = {}

    async def user_message(inputs, message_id):
        await notify("item/completed", {"turnId": turn_id, "item": {
            "id": message_id, "type": "userMessage", "content": inputs,
        }})

    async def conclude(text):
        nonlocal started
        await notify("item/completed", {"turnId": turn_id, "item": {
            "id": "fixture-reply", "type": "agentMessage", "phase": "final_answer", "text": text,
        }})
        started = False
        await notify("turn/completed", {"turn": {"id": turn_id, "status": "completed"}})

    async def continue_turn(needs_approval):
        try:
            await asyncio.sleep(6)
            if needs_approval:
                await send({"id": "fixture-approval", "method": "item/commandExecution/requestApproval", "params": {
                    "threadId": CHAT, "turnId": turn_id, "itemId": "fixture-tool", "command": "echo fixture",
                    "availableDecisions": ["accept", "decline"],
                }})
            else:
                await conclude("I reviewed the draft and posted the changes." if voice
                               else "A reply finished in the other workspace.")
        except ConnectionClosed:
            return

    async def show_live_feedback():
        try:
            await asyncio.sleep(3)
            await notify("item/completed", {"turnId": turn_id, "item": {
                "id": "fixture-note", "type": "agentMessage", "phase": "commentary", "text": "Checking the current changes.",
            }})
            await asyncio.sleep(6)
            steps = [{"step": "Inspect the fixture workspace", "status": "inProgress"},
                     {"step": "Summarize the changes", "status": "pending"}]
            await notify("turn/plan/updated", {"turnId": turn_id, "plan": steps})
            command = {"id": "fixture-tool", "type": "commandExecution", "command": "git status --short"}
            await notify("item/started", {"turnId": turn_id, "item": command})
            await notify("item/commandExecution/outputDelta", {
                "turnId": turn_id, "itemId": command["id"], "delta": "Fixture output is ready.",
            })
            await notify("turn/diff/updated", {"turnId": turn_id, "diff": "--- a/demo.txt\n+++ b/demo.txt\n@@ -1 +1 @@\n-old\n+new\n"})
            await asyncio.sleep(12)
            await notify("item/completed", {"turnId": turn_id, "item": {**command, "status": "completed", "exitCode": 0}})
            await notify("turn/plan/updated", {"turnId": turn_id, "plan": [{**step, "status": "completed"} for step in steps]})
            await conclude("The fixture turn is complete.")
        except ConnectionClosed:
            return

    async def compact_context():
        try:
            await asyncio.sleep(1)
            started_at = int(time.time() * 1000)
            item = {"id": "fixture-live-compaction", "type": "contextCompaction", "startedAtMs": started_at}
            await notify("item/started", {"turnId": turn_id, "item": item})
            await asyncio.sleep(7)
            await notify("item/completed", {"turnId": turn_id, "item": {**item, "completedAtMs": started_at + 7000}})
            await conclude("The release draft is ready.")
        except ConnectionClosed:
            return

    thread = {"id": CHAT, "name": "Release draft review" if voice else "Busy Codex fixture", "cwd": WORKSPACE,
              "status": {"type": "active" if live else "idle"}}
    thread_settings = {"model": "gpt-6.2-sol", "effort": "xhigh", "serviceTier": None}
    approval = None
    started = live
    turn_number = 1 if live else 0
    steering_number = 0
    turn_id = f"{TURN}-1" if live else None
    try:
        async for raw in socket:
            packet = json.loads(raw)
            method, request = packet.get("method"), packet.get("id")
            params = packet.get("params", {})
            if method == "initialized":
                continue
            if method is None and request == "fixture-approval" and started:
                if packet.get("result", {}).get("decision") != "decline":
                    continue
                await notify("serverRequest/resolved", {"requestId": request})
                await conclude("This reply survived switching workspaces.")
                continue
            if method == "initialize":
                if not params.get("capabilities", {}).get("experimentalApi"):
                    live = True
                    started = True
                    turn_number = 1
                    turn_id = f"{TURN}-1"
                    thread["status"] = {"type": "active"}
                result = {"codexHome": "/riptide-ux-fixture/codex-home"}
            elif method == "fs/createDirectory":
                result = {}
            elif method == "fs/writeFile":
                files[params["path"]] = params["dataBase64"]
                result = {}
            elif method == "fs/readFile" and params.get("path") in files:
                result = {"dataBase64": files[params["path"]]}
            elif method == "account/read":
                result = {"account": {"type": "chatgpt"}, "workspaceRouting": {"chatgptAccountId": "fixture-identity"}}
            elif voice and method == "thread/realtime/listVoices":
                result = {"voices": {"v1": ["arbor", "cove"], "v3": ["cove", "juniper", "spruce"]}}
            elif voice and method == "thread/realtime/start" and params.get("threadId") == CHAT:
                if params.get("voice") != "juniper" or "flushTranscriptTailOnSessionEnd" in params:
                    await send({"id": request, "error": {"code": -32602, "message": "Expected the selected voice with standard hangup routing."}})
                    continue
                await notify("thread/realtime/started", {"realtimeSessionId": "fixture-voice", "version": "v3"})
                await notify("thread/realtime/sdp", {"sdp": "v=0 fixture answer"})
                await notify("thread/realtime/transcript/delta", {"role": "user", "delta": "Check the draft"})
                result = {}
            elif voice and method == "thread/realtime/stop" and params.get("threadId") == CHAT:
                for role, text in (("user", "Check the draft."), ("assistant", "I’ll check it and reply here.")):
                    await notify("thread/realtime/item/completed", {"item": {
                        "id": f"fixture-speech-{role}", "type": "transcriptSegment",
                        "realtimeSessionId": "fixture-voice", "role": role, "text": text,
                    }})
                await notify("thread/realtime/closed", {"reason": "requested"})
                if started:
                    approval = asyncio.create_task(continue_turn(False))
                result = {}
            elif method == "thread/list":
                result = {"data": [thread]}
            elif method == "thread/start":
                result = {"thread": {**thread, "id": "new-fixture-thread", "name": "New Codex fixture"}, **thread_settings}
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
                history = [{"id": turn_id, "status": "inProgress", "items": [{
                    "id": "fixture-original", "type": "userMessage",
                    "content": [{"type": "text", "text": "Review the release draft"}],
                }]}] if live else []
                if compaction:
                    history.append({"id": "fixture-earlier-turn", "status": "completed", "items": [
                        {"id": "fixture-earlier-compaction", "type": "contextCompaction",
                         "startedAtMs": 1000, "completedAtMs": 25000},
                        {"id": "fixture-earlier-reply", "type": "agentMessage", "phase": "final_answer",
                         "text": "I finished reviewing the draft."},
                    ]})
                result = {"data": history}
                if live:
                    await notify_usage()
                    if (compaction or watch_progress) and params.get("limit") in (3, 30) and approval is None:
                        approval = asyncio.create_task(compact_context() if compaction else show_live_feedback())
            elif method == "turn/start" and not started:
                started = True
                turn_number += 1
                turn_id = f"{TURN}-{turn_number}"
                result = {"turn": {"id": turn_id}}
                inputs = params.get("input", [])
                await notify("turn/started", {"turn": {"id": turn_id}})
                await notify_usage()
                await user_message(inputs, "fixture-user-message")
                feedback = any("show live feedback" in item.get("text", "") for item in inputs)
                needs_approval = not any("finish without approval" in item.get("text", "") for item in inputs)
                if compaction:
                    approval = asyncio.create_task(compact_context())
                elif not voice:
                    approval = asyncio.create_task(show_live_feedback() if feedback else continue_turn(needs_approval))
            elif method == "turn/steer" and started and params.get("expectedTurnId") == turn_id:
                steering_number += 1
                await user_message(params.get("input", []), f"fixture-steer-{steering_number}")
                result = {"turnId": turn_id}
            else:
                await send({"id": request, "error": {"code": -32601, "message": "Not available in the UX fixture."}})
                continue
            await send({"id": request, "result": result})
    except ConnectionClosed:
        pass
    finally:
        if approval is not None:
            approval.cancel()


async def run(port_file, tls=None, live=False, watch_progress=False, compaction=False, voice=False):
    def authenticate(connection, request):
        if request.headers.get("Authorization") != f"Bearer {TOKEN}":
            return connection.respond(HTTPStatus.UNAUTHORIZED, "Fixture credential required.\n")

    handler = partial(fixture, live=live, watch_progress=watch_progress, compaction=compaction, voice=voice)
    async with serve(handler, "127.0.0.1", 0, process_request=authenticate, ssl=tls) as service:
        port_file.write_text(str(service.sockets[0].getsockname()[1]), encoding="utf-8")
        await service.serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Loopback-only App Server fixture for Riptide UI tests.")
    parser.add_argument("--port-file", required=True, type=Path)
    parser.add_argument("--tls-cert", type=Path)
    parser.add_argument("--tls-key", type=Path)
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--watch-progress", action="store_true")
    parser.add_argument("--compaction", action="store_true")
    parser.add_argument("--voice", action="store_true")
    args = parser.parse_args()
    if bool(args.tls_cert) != bool(args.tls_key):
        parser.error("--tls-cert and --tls-key must be used together")
    tls = None
    if args.tls_cert:
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(args.tls_cert, args.tls_key)
    asyncio.run(run(args.port_file, tls, args.live, args.watch_progress, args.compaction, args.voice))
