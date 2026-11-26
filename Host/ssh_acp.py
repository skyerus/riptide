import argparse
import asyncio
import json
import os
from pathlib import Path
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


async def serve(workspace, command, safari_mcp=None, attention_socket=None):
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
    openings = {}
    opened = set()

    def write(message):
        sys.stdout.buffer.write(message)
        sys.stdout.buffer.flush()

    async def to_agent():
        while line := await source.readline():
            packet = json.loads(line)
            if admitted(packet, workspace, pending):
                if attention_socket:
                    method = packet.get("method")
                    if method in ("session/new", "session/load") and len(openings) < 128:
                        openings[packet["id"]] = packet["params"].get("sessionId")
                    if method == "session/prompt" and packet["params"]["sessionId"] in opened:
                        from hermes_attention import exchange
                        try:
                            await exchange(attention_socket, {"operation": "watch", "chat": packet["params"]["sessionId"]})
                        except (OSError, ValueError, TimeoutError):
                            pass  # Alert availability must never interrupt a chat.
                if safari_mcp and packet.get("method") in ("session/new", "session/load"):
                    # The device can only send an empty MCP list. Supply this
                    # administrator-configured connector after validating the request.
                    packet["params"]["mcpServers"] = [safari_mcp]
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
            if rpc_id(request_id) and "method" not in packet and request_id in openings:
                held_id = openings.pop(request_id)
                if isinstance(packet.get("result"), dict):
                    chat = held_id or packet["result"].get("sessionId")
                    if isinstance(chat, str) and len(opened) < 128:
                        opened.add(chat)
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


async def serve_safari(socket_path, device):
    from safari_bridge import MAX_BODY, RelayError, browser_call

    loop = asyncio.get_running_loop()
    source = asyncio.StreamReader(limit=MAX_BODY)
    stdin, _ = await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(source), sys.stdin.buffer)
    try:
        while line := await asyncio.wait_for(source.readline(), 45):
            request = json.loads(line)
            if not isinstance(request, dict) or set(request) != {"operation", "body"} or not isinstance(
                    request["operation"], str) or not isinstance(request["body"], dict):
                raise ValueError("Invalid Safari request.")
            try:
                body = await asyncio.to_thread(
                    browser_call, Path(socket_path), device, request["operation"], request["body"])
                response = {"status": 200, "body": body}
            except RelayError as exc:
                response = {"status": exc.status, "body": {"error": str(exc)}}
            sys.stdout.buffer.write(json.dumps(response, ensure_ascii=False, allow_nan=False).encode() + b"\n")
            sys.stdout.buffer.flush()
    finally:
        stdin.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Narrow a dedicated OpenSSH key to Riptide’s ACP client.")
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--hermes-screen", nargs=2, metavar=("PROFILE_HOME", "HERMES"))
    parser.add_argument("--codex-dictation-auth", metavar="CODEX_AUTH_FILE")
    parser.add_argument("--safari", nargs=2, metavar=("BROWSER_SOCKET", "DEVICE_ID"))
    parser.add_argument("--safari-mcp-python", metavar="PYTHON")
    parser.add_argument("--attention-socket", type=Path)
    parser.add_argument("--pairing-config", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    requested = os.environ.get("SSH_ORIGINAL_COMMAND")
    if args.attention_socket and not args.attention_socket.is_absolute():
        parser.error("An absolute notification relay socket path is required.")
    if requested == "riptide-pair-hermes":
        if args.pairing_config is None:
            print(json.dumps({"error": "This SSH pairing cannot connect additional Hermes profiles."}))
            sys.exit(1)
        from hermes_pairing import serve as serve_pairing
        sys.exit(serve_pairing(args.pairing_config, Path(__file__).resolve()))
    if requested == "riptide-attention":
        if args.attention_socket is None:
            print('{"ok":false}')
            sys.exit(0)
        from hermes_attention import serve_ssh
        asyncio.run(serve_ssh(args.attention_socket))
        sys.exit(0)
    if requested == "riptide-dictation":
        if args.codex_dictation_auth is None:
            print(json.dumps({"error": "disabled"}))
            sys.exit(1)
        if not os.path.isabs(args.codex_dictation_auth):
            parser.error("An absolute Codex auth file path is required.")
        from codex_dictation import serve_ssh
        asyncio.run(serve_ssh(args.codex_dictation_auth))
        sys.exit(0)
    if requested == "riptide-safari":
        if args.safari is None:
            print(json.dumps({"status": 403, "body": {"error": "This SSH key has no Safari relay enabled."}}))
            sys.exit(1)
        socket_path, device = args.safari
        if not os.path.isabs(socket_path):
            parser.error("An absolute Safari relay socket is required.")
        try:
            asyncio.run(serve_safari(socket_path, device))
        except (TimeoutError, asyncio.TimeoutError):
            pass
        except (OSError, ValueError):
            parser.exit(1, "The Safari transport closed.\n")
        sys.exit(0)
    if requested == "riptide-hermes-screen":
        if args.hermes_screen is None:
            print(json.dumps({"event": "error", "message": "This SSH pairing has no Hermes screen."}))
            sys.exit(1)
        home, hermes = args.hermes_screen
        if not os.path.isabs(home) or not os.path.isdir(home) or not os.path.isabs(hermes):
            parser.error("An absolute Hermes profile and launcher are required.")
        adapter = os.path.join(os.path.dirname(os.path.realpath(__file__)), "hermes_screen.py")
        os.execv(sys.executable, [sys.executable, adapter, hermes, os.path.realpath(home)])
    if requested != "riptide-acp" or not command or not os.path.isabs(command[0]):
        parser.exit(1, "This key is only authorized for Riptide ACP.\n")
    if not os.path.isabs(args.workspace) or not os.path.isdir(args.workspace):
        parser.error("An existing absolute workspace is required.")
    safari_mcp = None
    if args.safari_mcp_python:
        socket_path = Path(args.safari[0]) if args.safari else None
        if socket_path is None or not socket_path.is_absolute() or socket_path.name != "browser.sock":
            parser.error("--safari-mcp-python requires --safari with an absolute browser.sock path.")
        if not os.path.isabs(args.safari_mcp_python):
            parser.error("An absolute Safari MCP Python path is required.")
        safari_mcp = {
            "name": "riptide_safari",
            "command": args.safari_mcp_python,
            "args": [str(Path(__file__).resolve().with_name("safari_mcp.py")), "--state-dir", str(socket_path.parent)],
            "env": [],
        }
    try:
        asyncio.run(serve(args.workspace, command, safari_mcp, args.attention_socket))
    except (OSError, ValueError):
        parser.exit(1, "The ACP transport closed.\n")
