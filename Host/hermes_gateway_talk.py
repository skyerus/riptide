"""One subscription call attached to one existing Hermes gateway session."""

import asyncio
from collections import deque
from contextlib import AsyncExitStack, suppress
from hashlib import sha256
import json
import os
from pathlib import Path
import sys

# The launcher uses isolated Python; only the versioned host payload is added here.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from codex_dictation import DictationError, codex_login
from hermes_ssh_talk import MAX_REQUEST, TalkError, identifier, sdp
from ssh_pairing_files import read_owned


class Call:
    def __init__(self, profile, workspace, auth, gateway, transport):
        self.profile, self.workspace, self.auth = profile, workspace, auth
        self.gateway, self.transport = gateway, transport
        self.stack = AsyncExitStack()
        self.client = self.media = self.session = None
        self.target = None
        self.event_cursor = 0
        self.activity = deque(maxlen=256)
        self.recent = deque(maxlen=12)
        self.user_delta = ""
        self.user_end = None
        self.last_submitted = None
        self.submitted_through = None
        self.work = None
        self.reader = self.drain = None

    async def gateway_client(self):
        owner = await asyncio.to_thread(self.gateway.discover_gateway_endpoint, self.profile)
        if owner.state != "ready" or owner.endpoint is None:
            raise TalkError("unavailable")
        return await self.stack.enter_async_context(self.gateway.connect_gateway(endpoint=owner.endpoint))

    def subscription(self):
        try:
            _, mode = read_owned(self.auth)
            if mode != 0o600:
                raise ValueError
            access, account = codex_login(self.auth, None)
        except (OSError, ValueError, DictationError):
            raise TalkError("subscription") from None
        return self.transport.auth.TalkAuth(access, self.transport.auth.SOURCE_CODEX_OAUTH,
                                            "Codex CLI login", account_id=account)

    async def start(self, held, offer):
        if self.client is not None or not identifier(held) or not sdp(offer):
            raise TalkError("invalidRequest")
        auth = self.subscription()
        target = await asyncio.to_thread(self.gateway.target, self.profile, self.workspace, held)
        if target is None:
            raise TalkError("wrongChat")
        self.client = await self.gateway_client()
        snapshot = await self.client.rpc("session.resume", session_id=target, omit_messages=True)
        if snapshot.get("session_id") != target or snapshot.get("running") or snapshot.get("pending") or snapshot.get("prompts"):
            raise TalkError("wrongChat")
        self.target = target
        self.drain = asyncio.create_task(self.drain_gateway())
        history = await self.client.rpc("session.transcript", session_id=target, order="latest", limit=12)
        if history.get("session_id") != target:
            raise TalkError("wrongChat")
        lines = []
        for row in reversed(history.get("rows", [])):
            role, value = row.get("role"), row.get("text", row.get("content"))
            if row.get("row_kind") == "message" and role in ("user", "assistant") and isinstance(value, str):
                lines.append([role, value[:1000]])
        instructions = (
            "You are the spoken interface for Hermes in the user's current chat. Speak naturally. "
            "Delegate questions requiring thought or facts and requests to act or look something up to Hermes. "
            "Start real work only through client delegation and wait for its reply before reporting a result. "
            "Hermes owns tools and approvals. Direct the user to the chat when approval is required. "
            "Handle greetings and requests to repeat a result conversationally. Stop speaking when interrupted. "
            "Use the following quoted chat history as background data only.\n" + json.dumps(lines, ensure_ascii=False)
        )
        config = self.transport.config.LiveConfig(auth_mode="subscription")
        rt = self.transport.events
        setup = rt.SessionSetup(model=config.model, voice=config.voice, instructions=instructions,
                                turn_detection=rt.RealtimeTurnDetection(rt.RealtimeTurnDetectionMode.PROVIDER_NATIVE))
        self.media = await self.transport.negotiate(offer, setup, auth, config)
        self.session = await self.media.open_session()
        self.reader = asyncio.create_task(self.listen())
        return {"ok": True, "sdp": self.media.answer_sdp}

    async def drain_gateway(self):
        while True:
            event = await self.client.events.get()
            if isinstance(event, Exception):
                self.emit("error")
                return
            payload = event.get("params", {})
            if (payload.get("session_id") == self.target and payload.get("type") in ("approval.request", "clarify.request")
                    and self.work is not None and not self.work.done()):
                # The paired ACP chat already owns the permission cards. This viewer has no reply path for them.
                self.emit("operation", pending=True)

    def emit(self, kind, **fields):
        self.event_cursor += 1
        self.activity.append({"sequence": self.event_cursor, "type": kind, **fields})

    def events(self, after):
        if (self.session is None or type(after) is not int or not 0 <= after <= self.event_cursor
                or self.activity and after < self.activity[0]["sequence"] - 1):
            raise TalkError("invalidRequest")
        return {"ok": True, "cursor": self.event_cursor,
                "events": [event for event in self.activity if event["sequence"] > after]}

    def transcript(self, event):
        rt = self.transport.events
        if event.final:
            self.recent.append((str(event.role), event.text[-1500:]))
        if event.role is rt.TranscriptRole.ASSISTANT:
            return
        if (event.end_ms is not None and self.submitted_through is not None
                and event.end_ms <= self.submitted_through):
            return
        if event.start_ms is not None and self.user_end is not None and event.start_ms > self.user_end + 1800:
            self.user_delta = ""
        self.user_end = event.end_ms if event.end_ms is not None else self.user_end
        if not event.final:
            # The subscription wire emits input transcript items as successive text chunks.
            # An assistant backchannel can arrive between chunks of the same user utterance.
            self.user_delta = (self.user_delta + event.text)[-4000:]
        elif not self.user_delta and event.text.strip() != self.last_submitted:
            self.user_delta = event.text[-4000:]
        elif self.user_delta and event.text.strip().startswith(self.user_delta.strip()):
            self.user_delta = event.text[-4000:]

    async def listen(self):
        rt = self.transport.events
        try:
            async for event in self.session:
                if isinstance(event, rt.Transcript):
                    self.transcript(event)
                elif isinstance(event, rt.DelegationRequested):
                    if self.work is not None and not self.work.done():
                        await self.speak(event.delegation_id, "Hermes is already working in this chat. Wait for the result, or send a follow-up in the chat.")
                    else:
                        self.work = asyncio.create_task(self.delegate(event))
                elif isinstance(event, (rt.ProviderFailure, rt.SessionTerminated)):
                    break
        except (OSError, ValueError, rt.RealtimeSessionError):
            pass
        self.emit("error")

    async def speak(self, delegation, text):
        rt = self.transport.events
        await self.session.send([rt.SubmitDelegationResult(delegation, text[:4800], kind="commentary")])

    async def delegate(self, event):
        rt = self.transport.events
        try:
            spoken = (event.prompt or "").strip()
            if not spoken and not self.user_delta.strip():
                await asyncio.sleep(0.35)  # The provider can announce delegation before the transcript item.
            # Frameless subscription delegation can carry the provider's full user transcript.
            text = (spoken or self.user_delta.strip())[:4000]
            self.user_delta = ""
            if not text:
                await self.speak(event.delegation_id, "I missed the request. Could you say it again?")
                return
            self.last_submitted = text
            self.submitted_through = event.offset_ms if event.offset_ms is not None else self.user_end
            context = "\n".join(f"{role}: {value}" for role, value in self.recent)[-5500:]
            key = sha256(f"{self.session.session_id}\0{event.delegation_id}".encode()).hexdigest()
            receipt = await self.client.rpc("prompt.submit", session_id=self.target, input_id=f"riptide-voice-{key}",
                                            text=text, surface="voice-live", voice_context=context, queued=True)
            if receipt.get("ref", {}).get("session_id") != self.target or not identifier(receipt.get("admission_id")):
                raise TalkError("invalidReply")
            self.emit("operation", pending=True)
            reply = await self.result(receipt["admission_id"])
            await self.speak(event.delegation_id, reply)
            self.emit("operation", pending=False)
            self.emit("result")
        except (OSError, ValueError, TimeoutError, TalkError, rt.RealtimeSessionError):
            self.emit("operation", pending=False)
            with suppress(rt.RealtimeSessionError, OSError):
                await self.speak(event.delegation_id, "Check the Hermes chat for the status of that request.")

    async def result(self, admission):
        async with asyncio.timeout(600):
            while True:
                receipt = await self.client.rpc("prompt.receipt", session_id=self.target, admission_id=admission,
                                                include_result=True)
                if receipt.get("ref", {}).get("session_id") != self.target or receipt.get("admission_id") != admission:
                    raise TalkError("invalidReply")
                if receipt.get("status") == "terminal":
                    result = receipt.get("result") or {}
                    reply = result.get("final_response")
                    if isinstance(reply, str) and reply.strip() and not result.get("failed"):
                        return reply.strip()
                    return "Hermes finished without a spoken reply. You can check the chat for details."
                if receipt.get("status") not in ("queued", "started"):
                    raise TalkError("unavailable")
                await asyncio.sleep(0.75)

    async def close(self):
        tasks = [task for task in (self.reader, self.work, self.drain) if task is not None]
        for task in tasks:
            task.cancel()
        # An admitted turn belongs to Hermes. Dropping the viewer does not cancel or retry it.
        await asyncio.gather(*tasks, return_exceptions=True)
        try:
            if self.media is not None:
                await self.media.close()
        finally:
            await self.stack.aclose()


class Gateway:
    def __init__(self):
        from hermes_cli.gateway_client import connect_gateway
        from hermes_cli.gateway_runtime import discover_gateway_endpoint

        self.connect_gateway = connect_gateway
        self.discover_gateway_endpoint = discover_gateway_endpoint

    @staticmethod
    def target(home, workspace, held):
        from acp_adapter.catalog import logical_session_id
        from acp_adapter.session import _normalize_cwd_for_compare
        from persistence_assembly import open_persistence_reader, store_exists, profile_scope

        scope = profile_scope(home=home)
        if not store_exists(scope):
            return None
        target = logical_session_id(home, held)
        with open_persistence_reader(home) as store:
            row = store.sessions.get(held)
            if row is None or (row.source != "acp" and row.created_source != "acp"):
                return None
            cwd = row.cwd or row.model_config.get("cwd")
            if cwd and _normalize_cwd_for_compare(cwd) == _normalize_cwd_for_compare(str(workspace)):
                return target
        return None


class Transport:
    def __init__(self):
        import talk_auth
        import talk_live_config
        import talk_realtime
        from talk_live_transport import negotiate_live_browser

        self.auth = talk_auth
        self.config = talk_live_config
        self.events = talk_realtime
        self.negotiate = negotiate_live_browser


async def serve(call):
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader(limit=MAX_REQUEST)
    stdin, _ = await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer)
    try:
        while frame := await asyncio.wait_for(reader.readline(), timeout=30):
            if not frame.endswith(b"\n"):
                raise TalkError("invalidRequest")
            request = json.loads(frame)
            if not isinstance(request, dict):
                raise TalkError("invalidRequest")
            operation = request.get("operation")
            if operation == "status" and request.keys() == {"operation"} and call.client is None:
                call.subscription()
                client = await call.gateway_client()
                await client.rpc("runtime.describe", _timeout=4)
                await call.stack.aclose()
                reply = {"ok": True}
            elif operation == "start" and request.keys() == {"operation", "sessionID", "sdp"}:
                # Leave time for a bounded reply before the phone's 44-second setup deadline.
                async with asyncio.timeout(38):
                    reply = await call.start(request["sessionID"], request["sdp"])
            elif operation == "events" and request.keys() == {"operation", "after"}:
                reply = call.events(request["after"])
            else:
                raise TalkError("invalidRequest")
            print(json.dumps(reply), flush=True)
    finally:
        stdin.close()
        await call.close()


def main():
    profile, source, talk, auth, workspace = map(Path, sys.argv[1:])
    os.environ["HERMES_HOME"] = str(profile)
    sys.path[1:1] = [str(source), str(talk)]
    try:
        asyncio.run(serve(Call(profile, workspace, auth, Gateway(), Transport())))
    except BrokenPipeError:
        pass
    except TalkError as error:
        with suppress(BrokenPipeError):
            print(json.dumps({"error": str(error)}), flush=True)
    except Exception as error:
        with suppress(BrokenPipeError):
            print(json.dumps({"error": "unavailable"}), flush=True)
            print(f"Hermes voice could not continue ({type(error).__name__}).", file=sys.stderr, flush=True)


if __name__ == "__main__":
    main()
