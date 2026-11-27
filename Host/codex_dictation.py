"""Transcribe one Riptide recording with the host's signed-in Codex account."""

import asyncio
import base64
import binascii
import hashlib
import hmac
import json
import os
import re
import stat
import sys
import tempfile
import uuid

MAX_AUDIO = 5_000_000
# Allow the base64 recording and its JSON envelope. Keep in sync with CodexDictation.swift.
MAX_REQUEST = 6_700_000
UPLOAD_TIMEOUT = 60
TRANSCRIBE_URL = "https://chatgpt.com/backend-api/transcribe"


class DictationError(Exception):
    pass


def codex_login(auth_file, expected):
    try:
        with open(auth_file, "rb") as file:
            mode = os.fstat(file.fileno()).st_mode
            if not stat.S_ISREG(mode) or stat.S_IMODE(mode) != 0o600:
                raise ValueError
            auth = json.loads(file.read(64 * 1024))
        if auth.get("auth_mode") != "chatgpt":
            raise ValueError
        tokens = auth["tokens"]
        access, account = tokens["access_token"], tokens["account_id"]
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,8192}", access) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", account):
            raise ValueError
        if expected is not None:
            segment = tokens["id_token"].split(".")[1]
            identity = json.loads(base64.urlsafe_b64decode(segment + "=" * (-len(segment) % 4)))
            email = identity.get("email") or ""
            fingerprint = base64.b64encode(hashlib.sha256(f"{account}\0{email}".encode()).digest())
            if not hmac.compare_digest(fingerprint, expected.encode()):
                raise DictationError("accountChanged")
        return access, account
    except (OSError, ValueError, TypeError, KeyError, IndexError, AttributeError):
        raise DictationError("signIn") from None


async def transcribe(audio, auth_file, expected):
    access, account = codex_login(auth_file, expected)
    boundary = uuid.uuid4().hex
    body = (
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="dictation.m4a"\r\n'
        'Content-Type: audio/mp4\r\n\r\n'
    ).encode() + audio + f"\r\n--{boundary}--\r\n".encode()

    # Keep authorization out of argv and the recording off disk on the host.
    with tempfile.TemporaryFile() as headers:
        headers.write((
            f"Authorization: Bearer {access}\nChatGPT-Account-ID: {account}\n"
            f"Content-Type: multipart/form-data; boundary={boundary}\n"
        ).encode())
        headers.seek(0)
        fd = headers.fileno()
        process = await asyncio.create_subprocess_exec(
            "curl", "-q", "--silent", "--proto", "=https", "--connect-timeout", "8", "--max-time", "60",
            "--max-filesize", "262144", "--header", f"@/dev/fd/{fd}", "--data-binary", "@-",
            "--write-out", "\n%{http_code}", TRANSCRIBE_URL,
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            pass_fds=(fd,),
        )
        try:
            stdout, _ = await process.communicate(body)
        finally:
            if process.returncode is None:
                try:
                    process.kill()
                except ProcessLookupError:
                    pass
                await process.wait()

    payload, _, status = stdout.rpartition(b"\n")
    if status in (b"401", b"403"):
        raise DictationError("signIn")
    if process.returncode or status != b"200":
        raise DictationError("serviceUnavailable")
    try:
        text = json.loads(payload)["text"].strip()
    except (ValueError, TypeError, KeyError, AttributeError):
        raise DictationError("serviceUnavailable") from None
    if not text:
        raise DictationError("noSpeech")
    return text


async def reply(frame, auth_file):
    try:
        if len(frame) > MAX_REQUEST:
            raise ValueError
        request = json.loads(frame)
        if not isinstance(request, dict) or set(request) - {"audio", "accountFingerprint"}:
            raise ValueError
        expected = request.get("accountFingerprint")
        if expected is not None and (not isinstance(expected, str) or
                                    not re.fullmatch(r"[A-Za-z0-9+/]{43}=", expected)):
            raise ValueError
        audio = base64.b64decode(request["audio"], validate=True)
        if not 8 < len(audio) <= MAX_AUDIO or audio[4:8] != b"ftyp":
            raise ValueError
    except (TypeError, ValueError, KeyError, binascii.Error):
        return {"error": "invalidAudio"}
    try:
        return {"text": await transcribe(audio, auth_file, expected)}
    except DictationError as error:
        return {"error": str(error)}
    except OSError:
        return {"error": "serviceUnavailable"}


async def serve_ssh(auth_file):
    loop = asyncio.get_running_loop()
    source = asyncio.StreamReader(limit=MAX_REQUEST)
    stdin, _ = await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(source), sys.stdin.buffer)
    try:
        frame = await asyncio.wait_for(source.readline(), timeout=UPLOAD_TIMEOUT)
        if frame:
            print(json.dumps(await reply(frame, auth_file)), flush=True)
    except (TimeoutError, ValueError):
        print(json.dumps({"error": "invalidAudio"}), flush=True)
    finally:
        stdin.close()
