"""Authorize a device-generated key for one operator-configured Hermes profile."""

import asyncio
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import sys

from ssh_pairing_files import Edit, key_identity, read_owned, require

PROFILE = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}")
MAX_REQUEST = 4096


async def verify_chat(command, workspace, chat_id):
    """Use the same ACP catalog and load capability the iPhone checks."""
    agent = await asyncio.create_subprocess_exec(
        *command, cwd=workspace, stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
        limit=2 * 1024 * 1024,
    )

    async def call(request_id, method, params):
        request = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        agent.stdin.write(json.dumps(request).encode() + b"\n")
        await agent.stdin.drain()
        while line := await agent.stdout.readline():
            frame = json.loads(line)
            if frame.get("id") == request_id:
                result = frame.get("result")
                if isinstance(result, dict):
                    return result
                break
        raise ValueError("Hermes did not confirm the main chat.")

    try:
        async with asyncio.timeout(10):
            initialized = await call(1, "initialize", {"protocolVersion": 1, "clientCapabilities": {}})
            capabilities = initialized.get("agentCapabilities", {})
            require(capabilities.get("loadSession") is True, "Hermes does not support loading this chat.")
            cursor = None
            seen = set()
            while True:
                listed = await call(2 + len(seen), "session/list", {"cursor": cursor} if cursor else {})
                if any(row.get("sessionId") == chat_id and row.get("cwd") == workspace
                       for row in listed.get("sessions", [])):
                    return
                cursor = listed.get("nextCursor")
                if not isinstance(cursor, str) or cursor in seen:
                    raise ValueError("The main chat is not listed by Hermes ACP in the configured workspace.")
                seen.add(cursor)
    finally:
        if agent.returncode is None:
            try:
                agent.kill()
            except ProcessLookupError:
                pass
        await agent.wait()


def register_key(path, public_key, command, profile):
    quoted = shlex.join(command).replace('"', r'\"')
    require(not any(c in quoted for c in "\r\n"), "Invalid on-host pairing configuration.")
    key = " ".join(public_key)
    entry = f'restrict,command="{quoted}" {key} riptide-{profile}'
    lock_path = path.with_name(".riptide-pairing.lock")
    with os.fdopen(os.open(lock_path, os.O_CREAT | os.O_NOFOLLOW | os.O_RDWR, 0o600), "r+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        content, mode = read_owned(path)
        require(content is not None, "The SSH authorized keys file does not exist.")
        source = content.decode()
        match = re.compile(rf"(?:^|\s){re.escape(key)}(?:\s|$)")
        matches = [line for line in source.splitlines() if not line.lstrip().startswith("#") and match.search(line)]
        if matches:
            require(matches == [entry], "This device key is already authorized for a different route.")
            return
        separator = "" if not source or source.endswith("\n") else "\n"
        Edit(path, content, (source + separator + entry + "\n").encode(), mode).apply()


def absolute_path(value):
    require(isinstance(value, str) and not any(c in value for c in "\x00\r\n"),
            "Invalid on-host pairing configuration.")
    path = Path(value)
    require(path.is_absolute(), "Pairing paths must be absolute.")
    return path


def pair(config_path, wrapper, request):
    require(isinstance(request, dict) and set(request) == {"profile", "publicKey"}, "Invalid pairing request.")
    profile = request["profile"]
    raw_key = request["publicKey"]
    require(isinstance(profile, str) and PROFILE.fullmatch(profile), "Invalid Hermes profile.")
    require(isinstance(raw_key, str) and re.fullmatch(r"ssh-ed25519 [A-Za-z0-9+/=]{50,100}", raw_key),
            "Invalid device public key.")
    config, _ = read_owned(absolute_path(str(config_path)))
    require(config is not None, "Hermes pairing is not configured on this host.")
    config = json.loads(config)
    target = config["targets"].get(profile)
    require(isinstance(target, dict), "This Hermes profile is not enabled for pairing.")
    name, chat_id = target["name"], target["mainSessionID"]
    workspace = absolute_path(target["workspace"])
    require(isinstance(name, str) and 0 < len(name) <= 80
            and isinstance(chat_id, str) and 0 < len(chat_id) <= 256 and workspace.is_dir(),
            "Invalid on-host pairing configuration.")
    hermes = absolute_path(config["hermes"])
    keys = absolute_path(config["authorizedKeys"])
    command = [str(hermes), "-p", profile, "acp"]
    key, _ = key_identity(raw_key)
    asyncio.run(verify_chat(command, str(workspace), chat_id))
    register_key(keys, key, [sys.executable, str(wrapper), "--workspace", str(workspace), "--", *command], profile)
    return {"name": name, "workspace": str(workspace), "mainSessionID": chat_id}


def serve(config_path, wrapper):
    try:
        frame = sys.stdin.buffer.readline(MAX_REQUEST + 1)
        require(len(frame) <= MAX_REQUEST and frame.endswith(b"\n"), "Invalid pairing request.")
        reply = pair(config_path, wrapper, json.loads(frame))
    except ValueError as error:
        reply = {"error": str(error)}
    except (KeyError, TypeError, AttributeError, OSError):
        reply = {"error": "The host could not complete this Hermes pairing."}
    print(json.dumps(reply), flush=True)
    return int("error" in reply)
