import argparse
import asyncio
import json
import os
import sys

MAX_FRAME = 2 * 1024 * 1024
REQUESTS = {
    "initialize": {"protocolVersion", "clientCapabilities", "clientInfo"},
    "session/list": {"cursor", "cwd"},
    "session/new": {"cwd", "mcpServers"},
    "session/load": {"sessionId", "cwd", "mcpServers"},
    "session/prompt": {"sessionId", "prompt"},
    "session/cancel": {"sessionId"},
    "session/set_config_option": {"sessionId", "configId", "value"},
}


def rpc_id(value):
    return type(value) in (int, str)


def admitted(packet, workspace, pending):
    if not isinstance(packet, dict) or packet.get("jsonrpc") != "2.0":
        return False
    method = packet.get("method")
    if method is None:
        request_id = packet.get("id")
        if not rpc_id(request_id) or request_id not in pending:
            return False
        if not (set(packet) in ({"jsonrpc", "id", "result"}, {"jsonrpc", "id", "error"})):
            return False
        pending.remove(request_id)
        return True
    params = packet.get("params")
    if (not isinstance(method, str) or method not in REQUESTS or
            not isinstance(params, dict) or params.keys() - REQUESTS[method] or
            packet.keys() - {"jsonrpc", "id", "method", "params"}):
        return False
    if method != "session/cancel" and not rpc_id(packet.get("id")):
        return False
    if method == "initialize":
        return params.get("protocolVersion") == 1 and params.get("clientCapabilities") == {}
    if method == "session/list":
        return params.get("cwd", workspace) == workspace
    if method in ("session/new", "session/load"):
        if params.get("cwd") != workspace or params.get("mcpServers") != []:
            return False
    if method != "session/new" and not isinstance(params.get("sessionId"), str):
        return False
    if method == "session/set_config_option":
        return params.get("configId") in ("model", "effort", "reasoning_effort") and isinstance(params.get("value"), str)
    if method == "session/prompt":
        blocks = params.get("prompt")
        return isinstance(blocks, list) and bool(blocks) and all(
            isinstance(block, dict) and set(block) == {"type", "text"}
            and block["type"] == "text" and isinstance(block["text"], str) for block in blocks
        )
    return True


async def serve(workspace, command):
    loop = asyncio.get_running_loop()
    source = asyncio.StreamReader(limit=MAX_FRAME)
    stdin, _ = await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(source), sys.stdin.buffer)
    try:
        agent = await asyncio.create_subprocess_exec(
            *command, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            cwd=workspace, limit=MAX_FRAME,
        )
    except BaseException:
        stdin.close()
        raise
    pending = set()

    def write(message):
        sys.stdout.buffer.write(message)
        sys.stdout.buffer.flush()

    async def to_agent():
        while line := await source.readline():
            packet = json.loads(line)
            if admitted(packet, workspace, pending):
                agent.stdin.write(json.dumps(packet, allow_nan=False).encode() + b"\n")
                await agent.stdin.drain()
            elif isinstance(packet, dict) and rpc_id(packet.get("id")):
                write(json.dumps({
                    "jsonrpc": "2.0", "id": packet["id"],
                    "error": {"code": -32602, "message": "Request is outside this SSH ACP pairing’s allowed scope."},
                }).encode() + b"\n")

    async def from_agent():
        while line := await agent.stdout.readline():
            packet = json.loads(line)
            request_id = packet.get("id")
            if isinstance(packet.get("method"), str) and rpc_id(request_id):
                if len(pending) >= 128:
                    raise ValueError("Too many pending ACP requests.")
                pending.add(request_id)
            write(line)

    pumps = [asyncio.create_task(action()) for action in (to_agent, from_agent)]
    try:
        done, _ = await asyncio.wait(pumps, return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            task.result()
    finally:
        stdin.close()
        for task in pumps:
            task.cancel()
        await asyncio.gather(*pumps, return_exceptions=True)
        agent.stdin.close()
        if agent.returncode is None:
            try:
                await asyncio.wait_for(agent.wait(), timeout=2)
            except TimeoutError:
                try:
                    agent.kill()
                except ProcessLookupError:
                    pass
                await agent.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Narrow a dedicated OpenSSH key to Riptide’s ACP client.")
    parser.add_argument("--workspace", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if os.environ.get("SSH_ORIGINAL_COMMAND") != "riptide-acp" or not command or not os.path.isabs(command[0]):
        parser.exit(1, "This key is only authorized for Riptide ACP.\n")
    if not os.path.isabs(args.workspace) or not os.path.isdir(args.workspace):
        parser.error("An existing absolute workspace is required.")
    try:
        asyncio.run(serve(args.workspace, command))
    except (OSError, ValueError):
        parser.exit(1, "The ACP transport closed.\n")
