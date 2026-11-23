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

MAX_FRAME = 2 * 1024 * 1024


def read_token(path):
    with Path(path).open(encoding="ascii") as file:
        if stat.S_IMODE(os.fstat(file.fileno()).st_mode) != 0o600:
            raise ValueError("The host token file must be mode 0600.")
        token = file.read(4097).strip()
    if not re.fullmatch(r"[a-zA-Z0-9_.~+/=\-]{32,4096}", token):
        raise ValueError("Expected a strong bearer token.")
    return token


def rpc_frame(text):
    packet = json.loads(text)
    if not isinstance(packet, dict) or packet.get("jsonrpc") != "2.0":
        raise ValueError("Expected one ACP JSON-RPC object per frame.")
    return json.dumps(packet, ensure_ascii=False, separators=(",", ":"))


def bridge_server(port, token, command):
    active = set()

    def authenticate(connection, request):
        if request.path != "/acp":
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
            process = await asyncio.create_subprocess_exec(
                *command, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                limit=MAX_FRAME,
            )

            async def to_agent():
                async for message in socket:
                    if not isinstance(message, str):
                        raise ValueError("Expected a text frame.")
                    process.stdin.write((rpc_frame(message) + "\n").encode())
                    await process.stdin.drain()

            async def to_phone():
                while line := await process.stdout.readline():
                    await socket.send(rpc_frame(line.decode()))

            pumps = [asyncio.create_task(to_agent()), asyncio.create_task(to_phone())]
            done, _ = await asyncio.wait(pumps, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                task.result()
        except ConnectionClosed:
            pass
        except (OSError, ValueError):
            await socket.close(1011, "ACP transport closed")
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
        max_size=MAX_FRAME, open_timeout=8, close_timeout=3,
    )


async def run(args):
    async with bridge_server(args.port, read_token(args.token_file), args.command) as bridge:
        print(f"ACP bridge on 127.0.0.1:{bridge.sockets[0].getsockname()[1]}", flush=True)
        await bridge.serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Carry stdio ACP over a host-owned private TLS proxy.")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--token-file", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ["--"]:
        args.command.pop(0)
    if not args.command:
        parser.error("Provide a fixed ACP command after --.")
    try:
        asyncio.run(run(args))
    except KeyboardInterrupt:
        pass
