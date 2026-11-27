import argparse
import asyncio
import hmac
import json
import os
import re
import stat
from http import HTTPStatus
from pathlib import Path

from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed

import codex_dictation
from agent_profile import PROFILE_UPDATE, connector as profile_connector, publish_changes, validate_state
from ssh_acp import STAGE_ATTACHMENTS, advertise_attachments, rpc_id, stage_attachments

MAX_FRAME = 2 * 1024 * 1024
DICTATION_PATH = "/riptide-dictation"


def read_token(path):
    with Path(path).open(encoding="ascii") as file:
        if stat.S_IMODE(os.fstat(file.fileno()).st_mode) != 0o600:
            raise ValueError("The host token file must be mode 0600.")
        token = file.read(4097).strip()
    if not re.fullmatch(r"[a-zA-Z0-9_.~+/=\-]{32,4096}", token):
        raise ValueError("Expected a strong bearer token.")
    return token


def rpc_packet(text):
    packet = json.loads(text)
    if not isinstance(packet, dict) or packet.get("jsonrpc") != "2.0":
        raise ValueError("Expected one ACP JSON-RPC object per frame.")
    return packet


def bridge_server(port, token, command, dictation_auth=None, profile_state=None):
    active = set()
    connector = profile_connector(profile_state) if profile_state is not None else None

    def authenticate(connection, request):
        if not ((request.path == "/acp" and command) or (request.path == DICTATION_PATH and dictation_auth)):
            return connection.respond(HTTPStatus.NOT_FOUND, "Not found\n")
        values = request.headers.get_all("Authorization")
        if len(values) != 1 or not hmac.compare_digest(values[0].encode(), f"Bearer {token}".encode()):
            return connection.respond(HTTPStatus.UNAUTHORIZED, "Pairing token required\n")
        if len(active) >= 4:
            return connection.respond(HTTPStatus.SERVICE_UNAVAILABLE, "ACP bridge is busy\n")
        return None

    async def relay(socket):
        if len(active) >= 4:
            await socket.close(1013, "ACP bridge is busy")
            return
        active.add(socket)
        process = None
        pumps = []
        try:
            if socket.request.path == DICTATION_PATH:
                frame = await asyncio.wait_for(socket.recv(), timeout=codex_dictation.UPLOAD_TIMEOUT)
                result = await codex_dictation.reply(frame, dictation_auth) if isinstance(frame, str) else {"error": "invalidAudio"}
                await socket.send(json.dumps(result))
                return

            process = await asyncio.create_subprocess_exec(
                *command, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                limit=MAX_FRAME,
            )

            initialize_id = None
            initialized = asyncio.Event()

            async def send_profile(packet):
                await socket.send(json.dumps(packet))

            async def to_agent():
                nonlocal initialize_id
                async for message in socket:
                    if not isinstance(message, str):
                        raise ValueError("Expected a text frame.")
                    if dictation_auth and len(message.encode()) > MAX_FRAME:
                        await socket.close(1009, "ACP frame is too large")
                        return
                    packet = rpc_packet(message)
                    method = packet.get("method")
                    if method == STAGE_ATTACHMENTS and initialized.is_set():
                        await socket.send(json.dumps(stage_attachments(packet)))
                        continue
                    if method == "initialize" and rpc_id(packet.get("id")):
                        initialize_id = packet["id"]
                    if connector and method in ("session/new", "session/load"):
                        params = packet.get("params")
                        if isinstance(params, dict) and params.get("mcpServers") == []:
                            params["mcpServers"] = [connector]
                    process.stdin.write((json.dumps(packet, ensure_ascii=False, separators=(",", ":")) + "\n").encode())
                    await process.stdin.drain()

            async def to_phone():
                while line := await process.stdout.readline():
                    packet = rpc_packet(line.decode())
                    if packet.get("method") == PROFILE_UPDATE:
                        continue
                    if rpc_id(packet.get("id")) and packet["id"] == initialize_id and "method" not in packet:
                        if advertise_attachments(packet):
                            initialized.set()
                    await socket.send(json.dumps(packet, ensure_ascii=False, separators=(",", ":")))

            pumps = [asyncio.create_task(to_agent()), asyncio.create_task(to_phone())]
            if connector:
                pumps.append(asyncio.create_task(publish_changes(profile_state, initialized, send_profile)))
            done, _ = await asyncio.wait(pumps, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                task.result()
        except ConnectionClosed:
            pass
        except (OSError, ValueError, TimeoutError):
            reason = "Dictation transport closed" if socket.request.path == DICTATION_PATH else "ACP transport closed"
            await socket.close(1011, reason)
        finally:
            for task in pumps:
                task.cancel()
            await asyncio.gather(*pumps, return_exceptions=True)
            if process is not None:
                process.stdin.close()
                if process.returncode is None:
                    try:
                        process.terminate()
                        await asyncio.wait_for(process.wait(), timeout=3)
                    except TimeoutError:
                        process.kill()
                        await process.wait()
                    except ProcessLookupError:
                        pass
            active.discard(socket)

    return serve(
        relay, "127.0.0.1", port, process_request=authenticate, origins=[None],
        max_size=codex_dictation.MAX_REQUEST if dictation_auth else MAX_FRAME, open_timeout=8, close_timeout=3,
    )


async def run(args):
    async with bridge_server(args.port, read_token(args.token_file), args.command, args.codex_dictation_auth,
                             args.agent_profile_state) as bridge:
        name = "ACP bridge" if args.command else "Dictation relay"
        print(f"{name} on 127.0.0.1:{bridge.sockets[0].getsockname()[1]}", flush=True)
        await bridge.serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Carry stdio ACP over a host-owned private TLS proxy.")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--codex-dictation-auth", metavar="CODEX_AUTH_FILE")
    parser.add_argument("--agent-profile-state", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ["--"]:
        args.command.pop(0)
    if args.codex_dictation_auth and not os.path.isabs(args.codex_dictation_auth):
        parser.error("An absolute Codex auth file path is required.")
    if not (args.command or args.codex_dictation_auth):
        parser.error("Provide a fixed ACP command after -- or enable Codex dictation.")
    if args.agent_profile_state:
        try:
            validate_state(args.agent_profile_state)
        except (OSError, ValueError) as error:
            parser.error(str(error))
    try:
        asyncio.run(run(args))
    except KeyboardInterrupt:
        pass
