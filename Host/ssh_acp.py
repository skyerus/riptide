import argparse
import asyncio
import base64
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile

from agent_profile import PROFILE_UPDATE, connector as profile_connector, publish_changes

MAX_FRAME = 2 * 1024 * 1024
MAX_ATTACHMENT_BYTES = 1024 * 1024
PRIVATE_FILE_LIMIT = 100 * 1024 * 1024
PRIVATE_FILE_CHUNK = 512 * 1024
PRIVATE_FILE_GREETING = {"version": 1, "streaming": {"chunkBytes": PRIVATE_FILE_CHUNK, "byteLimit": PRIVATE_FILE_LIMIT}}
STAGE_ATTACHMENTS = "riptide/stageAttachments"
REQUESTS = {
    "initialize": {"protocolVersion", "clientCapabilities", "clientInfo"},
    "session/list": {"cursor", "cwd"},
    "session/new": {"cwd", "mcpServers"},
    "session/load": {"sessionId", "cwd", "mcpServers"},
    "session/prompt": {"sessionId", "prompt"},
    "_riptide/session/steer": {"sessionId", "text", "admissionId"},
    "session/cancel": {"sessionId"},
    "session/set_config_option": {"sessionId", "configId", "value"},
}


def rpc_id(value):
    return type(value) in (int, str)


def advertise_attachments(packet):
    result = packet.get("result")
    if not isinstance(result, dict) or result.get("protocolVersion") != 1:
        return
    capabilities = result.get("agentCapabilities")
    if not isinstance(capabilities, dict):
        capabilities = result["agentCapabilities"] = {}
    metadata = capabilities.get("_meta")
    if not isinstance(metadata, dict):
        metadata = capabilities["_meta"] = {}
    metadata["riptide.app/attachments"] = 1
    return True


def stage_attachments(packet):
    response = {"jsonrpc": "2.0", "id": packet.get("id")}
    try:
        if set(packet) != {"jsonrpc", "id", "method", "params"} or not rpc_id(response["id"]):
            raise ValueError
        params = packet["params"]
        if not isinstance(params, dict) or set(params) != {"files"}:
            raise ValueError
        files = params["files"]
        if not isinstance(files, list) or not 1 <= len(files) <= 4:
            raise ValueError
        response["result"] = {"paths": store_files(files, prefix="riptide-attachments-")}
    except (ValueError, OSError):
        response["error"] = {"code": -32602, "message": "The host couldn’t stage these attachments (1 MB total)."}
    return response


def store_files(files, *, prefix):
    decoded = []
    total = 0
    for item in files:
        if not isinstance(item, dict) or set(item) != {"name", "dataBase64"}:
            raise ValueError
        name, encoded = item["name"], item["dataBase64"]
        if not valid_filename(name) or not isinstance(encoded, str):
            raise ValueError
        data = base64.b64decode(encoded, validate=True)
        total += len(data)
        if total > MAX_ATTACHMENT_BYTES:
            raise ValueError
        decoded.append((name, data))
    # A private random directory keeps files owner-only and avoids overwrites.
    directory = Path(tempfile.mkdtemp(prefix=prefix))
    try:
        paths = []
        for index, (name, data) in enumerate(decoded, start=1):
            path = directory / f"{index}-{name}"
            with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as file:
                file.write(data)
            paths.append(str(path))
        return paths
    except (ValueError, OSError):
        shutil.rmtree(directory, ignore_errors=True)
        raise


def valid_filename(name):
    return (isinstance(name, str) and name not in (".", "..")
            and re.fullmatch(r"[A-Za-z0-9._-]{1,120}", name) is not None)


async def private_file_frame(source):
    line = await asyncio.wait_for(source.readline(), 60)
    if not line:
        return None
    if not line.endswith(b"\n"):
        raise ValueError
    frame = json.loads(line)
    if not isinstance(frame, dict):
        raise ValueError
    return frame


async def receive_file_chunks(source, header):
    filename, size = header["name"], header["size"]
    if not valid_filename(filename) or type(size) is not int or not 0 <= size <= PRIVATE_FILE_LIMIT:
        raise ValueError
    directory = Path(tempfile.mkdtemp(prefix="riptide-private-file-"))
    partial = directory / ".partial"
    received = 0
    completed = False
    try:
        with os.fdopen(os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as file:
            print('{"received":0}', flush=True)
            while received < size:
                chunk = await private_file_frame(source)
                if chunk is None or set(chunk) != {"dataBase64"} or not isinstance(chunk["dataBase64"], str):
                    raise ValueError
                data = base64.b64decode(chunk["dataBase64"], validate=True)
                if not 0 < len(data) <= min(PRIVATE_FILE_CHUNK, size - received):
                    raise ValueError
                file.write(data)
                received += len(data)
                print(json.dumps({"received": received}), flush=True)
            finish = await private_file_frame(source)
            if finish is None or set(finish) != {"complete"} or finish["complete"] is not True:
                raise ValueError
        path = directory / f"1-{filename}"
        partial.rename(path)
        completed = True
        return str(path)
    finally:
        if not completed:
            shutil.rmtree(directory, ignore_errors=True)


async def receive_private_file():
    loop = asyncio.get_running_loop()
    source = asyncio.StreamReader(limit=MAX_FRAME - 1)
    stdin, _ = await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(source), sys.stdin.buffer)
    # The client waits for this handshake before sending any file bytes.
    try:
        print(json.dumps(PRIVATE_FILE_GREETING), flush=True)
        try:
            header = await private_file_frame(source)
            if header is None:
                return
            if set(header) == {"name", "size"}:
                path = await receive_file_chunks(source, header)
            else:
                path, = store_files([header], prefix="riptide-private-file-")
        except (ValueError, OSError, asyncio.TimeoutError):
            print('{"error":"uploadRejected"}', flush=True)
            return
        try:
            print(json.dumps({"path": path}), flush=True)
        except OSError:
            shutil.rmtree(Path(path).parent, ignore_errors=True)
            raise
    finally:
        stdin.close()


def prompt_block(block):
    if not isinstance(block, dict):
        return False
    if block.get("type") == "text":
        return set(block) == {"type", "text"} and isinstance(block["text"], str)
    if (block.get("type") != "image" or set(block) != {"type", "mimeType", "data"}
            or not isinstance(block["data"], str)):
        return False
    if block["mimeType"] not in ("image/jpeg", "image/png"):
        return False
    try:
        data = base64.b64decode(block["data"], validate=True)
    except ValueError:
        return False
    signature = b"\xff\xd8\xff" if block["mimeType"] == "image/jpeg" else b"\x89PNG\r\n\x1a\n"
    return len(data) <= MAX_ATTACHMENT_BYTES and data.startswith(signature)


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
        if params.get("protocolVersion") != 1:
            return False
        capabilities = params.get("clientCapabilities")
        if capabilities == {}:
            return True
        if not isinstance(capabilities, dict) or capabilities.keys() != {"_meta"}:
            return False
        metadata = capabilities["_meta"]
        return (isinstance(metadata, dict) and metadata.keys() == {"app.riptide.assistantProgress"}
                and metadata["app.riptide.assistantProgress"] is True)
    if method == "session/list":
        return params.get("cwd", workspace) == workspace
    if method in ("session/new", "session/load"):
        if params.get("cwd") != workspace or params.get("mcpServers") != []:
            return False
    if method != "session/new" and not isinstance(params.get("sessionId"), str):
        return False
    if method == "session/set_config_option":
        if params.get("configId") == "service_tier":
            return (isinstance(params.get("value"), str) and
                    params["value"] in ("normal", "fast", "auto", "cold", "ultrafast"))
        return params.get("configId") in ("model", "effort", "reasoning_effort") and isinstance(params.get("value"), str)
    if method == "_riptide/session/steer":
        text = params.get("text")
        admission = params.get("admissionId")
        return (isinstance(text, str) and bool(text.strip()) and len(text) <= 65_536
                and ("admissionId" not in params or isinstance(admission, str) and 0 < len(admission) <= 256))
    if method == "session/prompt":
        blocks = params.get("prompt")
        return isinstance(blocks, list) and bool(blocks) and all(map(prompt_block, blocks))
    return True


async def serve(workspace, command, browser_mcp=None, attention_socket=None, pairing_config=None,
                profile_state=None, attention_scope=None):
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
    connectors = [browser_mcp] if browser_mcp else []
    if pairing_config is not None:
        connectors.append({
            "name": "riptide_pairing", "command": sys.executable,
            "args": [str(Path(__file__).resolve().with_name("agent_pairing_mcp.py")),
                     "--config", str(pairing_config)],
            "env": [],
        })
    if profile_state is not None:
        connectors.append(profile_connector(profile_state))
    pending = set()
    openings = {}
    opened = set()
    initialize_id = None
    initialized = asyncio.Event()

    def write(message):
        sys.stdout.buffer.write(message)
        sys.stdout.buffer.flush()

    async def send_profile(packet):
        write(json.dumps(packet).encode() + b"\n")

    async def to_agent():
        nonlocal initialize_id
        while line := await source.readline():
            packet = json.loads(line)
            method = packet.get("method") if isinstance(packet, dict) else None
            if method == STAGE_ATTACHMENTS and initialized.is_set() and packet.get("jsonrpc") == "2.0":
                reply = stage_attachments(packet)
                write(json.dumps(reply).encode() + b"\n")
            elif admitted(packet, workspace, pending):
                if method == "initialize":
                    initialize_id = packet["id"]
                if attention_socket:
                    if method in ("session/new", "session/load") and len(openings) < 128:
                        openings[packet["id"]] = packet["params"].get("sessionId")
                    if method == "session/prompt" and packet["params"]["sessionId"] in opened:
                        from hermes_attention import exchange
                        try:
                            request = {"operation": "watch", "chat": packet["params"]["sessionId"]}
                            if attention_scope is not None:
                                request["scope"] = attention_scope
                            await exchange(attention_socket, request)
                        except (OSError, ValueError, TimeoutError):
                            pass  # Alert availability must never interrupt a chat.
                if connectors and method in ("session/new", "session/load"):
                    # Only the host can attach connectors to a validated ACP request.
                    packet["params"]["mcpServers"] = connectors
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
            if packet.get("method") == PROFILE_UPDATE:
                continue
            request_id = packet.get("id")
            if rpc_id(request_id) and "method" not in packet and request_id == initialize_id:
                if advertise_attachments(packet):
                    initialized.set()
                line = json.dumps(packet).encode() + b"\n"
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
    if profile_state is not None:
        pumps.append(asyncio.create_task(publish_changes(profile_state, initialized, send_profile)))
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
    parser.add_argument("--hermes-groups", nargs=2, metavar=("PROFILE_HOME", "HERMES"))
    parser.add_argument("--hermes-screen", nargs=2, metavar=("PROFILE_HOME", "HERMES"))
    parser.add_argument("--codex-dictation-auth", metavar="CODEX_AUTH_FILE")
    parser.add_argument("--hermes-talk-config", type=Path)
    parser.add_argument("--hermes-browser-mcp", nargs=2, metavar=("PYTHON", "HERMES_SOURCE"))
    parser.add_argument("--attention-socket", type=Path)
    parser.add_argument("--attention-profile")
    parser.add_argument("--pairing-config", type=Path)
    parser.add_argument("--agent-profile-state", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    requested = os.environ.get("SSH_ORIGINAL_COMMAND")
    if args.agent_profile_state and not args.agent_profile_state.is_absolute():
        parser.error("An absolute agent profile state path is required.")
    if args.pairing_config and not args.pairing_config.is_absolute():
        parser.error("An absolute pairing manifest path is required.")
    if args.attention_socket and not args.attention_socket.is_absolute():
        parser.error("An absolute notification relay socket path is required.")
    attention_scope = None
    if args.attention_profile is not None:
        from ssh_pairing_files import PROFILE
        if args.attention_socket is None or not PROFILE.fullmatch(args.attention_profile):
            parser.error("A Hermes profile and private relay socket are required for scoped alerts.")
        attention_scope = {"profile": args.attention_profile, "workspace": args.workspace}
    if requested == "riptide-pair-hermes":
        if args.pairing_config is None:
            print(json.dumps({"error": "This SSH pairing cannot connect additional Hermes profiles."}))
            sys.exit(1)
        from hermes_pairing import serve as serve_pairing
        sys.exit(serve_pairing(args.pairing_config, Path(__file__).resolve(),
                               codex_dictation_auth=args.codex_dictation_auth, attention_socket=args.attention_socket,
                               hermes_talk_config=args.hermes_talk_config))
    if requested == "riptide-attention":
        if args.attention_socket is None:
            print('{"ok":false}')
            sys.exit(0)
        from hermes_attention import serve_ssh
        asyncio.run(serve_ssh(args.attention_socket, attention_scope))
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
    if requested == "riptide-hermes-talk":
        from hermes_ssh_talk import serve as serve_talk
        serve_talk(args.hermes_talk_config, home=args.hermes_screen[0] if args.hermes_screen else None,
                   workspace=args.workspace, command=command)
        sys.exit(0)
    if requested == "riptide-hermes-groups":
        if args.hermes_groups is None:
            print(json.dumps({"error": {"code": -32601, "message": "Group chats are not enabled for this SSH pairing."}}))
            sys.exit(0)
        home, hermes = args.hermes_groups
        if not os.path.isabs(home) or not os.path.isdir(home) or not os.path.isabs(hermes):
            parser.error("An absolute Hermes profile and launcher are required.")
        adapter = os.path.join(os.path.dirname(os.path.realpath(__file__)), "hermes_groups.py")
        os.execv(sys.executable, [sys.executable, adapter, hermes, os.path.realpath(home)])
    if requested == "riptide-hermes-screen":
        if args.hermes_screen is None:
            print(json.dumps({"event": "error", "message": "This SSH pairing has no Hermes screen."}))
            sys.exit(1)
        home, hermes = args.hermes_screen
        if not os.path.isabs(home) or not os.path.isdir(home) or not os.path.isabs(hermes):
            parser.error("An absolute Hermes profile and launcher are required.")
        adapter = os.path.join(os.path.dirname(os.path.realpath(__file__)), "hermes_screen.py")
        os.execv(sys.executable, [sys.executable, adapter, hermes, os.path.realpath(home)])
    if requested not in ("riptide-acp", "riptide-private-file") or not command or not os.path.isabs(command[0]):
        parser.exit(1, "This key is only authorized for Riptide ACP.\n")
    if not os.path.isabs(args.workspace) or not os.path.isdir(args.workspace):
        parser.error("An existing absolute workspace is required.")
    if requested == "riptide-private-file":
        try:
            asyncio.run(receive_private_file())
        except OSError:
            parser.exit(1, "The private file transport closed.\n")
        sys.exit(0)
    browser_mcp = None
    if args.hermes_browser_mcp:
        python, source = map(Path, args.hermes_browser_mcp)
        if args.hermes_screen is None or not python.is_absolute() or not source.is_absolute() or not source.is_dir():
            parser.error("The Chrome connector requires --hermes-screen and the absolute Hermes Python and source paths.")
        home = Path(args.hermes_screen[0])
        if not home.is_absolute() or not home.is_dir():
            parser.error("Use an existing absolute Hermes screen profile.")
        from hermes_browser_mcp import connector
        browser_mcp = connector(python, source, home.resolve())
    try:
        asyncio.run(serve(args.workspace, command, browser_mcp, args.attention_socket,
                          args.pairing_config, args.agent_profile_state, attention_scope))
    except (OSError, ValueError):
        parser.exit(1, "The ACP transport closed.\n")
