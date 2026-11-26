# Live steering over ACP

Riptide sends `_riptide/session/steer` for an active ACP reply. The paired adapter accepts `sessionId` and literal `text`. It returns `steered` after the running turn accepts the input, or `idle` when that turn has already ended. An unavailable extension or refusal leaves the draft in the composer. Queue is available over ordinary ACP.

Apply the matching patch from a checkout at the pinned revision. Check it with `git apply --check <patch>` before `git apply <patch>`. Rebuild or restart the ACP adapter from that source and reopen the chat. The HTTPS bridge passes the extension through. For SSH, stage the revised Riptide SSH payload with `Host/update_ssh_release.py` so the forced command admits the extension.

- [Hermes](hermes-acp-steering.patch) targets `8fc0374447313e276f6b9a2764bfc750190c966a` and the gateway-backed ACP adapter. The gateway checks the execution generation attached to the original ACP prompt. The native correction preserves the turn and uses `turn/steer` on a Codex-backed execution.
- [OpenClaw](openclaw-acp-steering.patch) targets `e088e2e019ee1a31bd577e72191578b3859dc5ea`. Its gateway must authorize `sessions.steerTarget` and `sessions.steerActive` for the ACP connection. OpenClaw requires `gateway.sessionControl.steeringEnabled` and a current authenticated person with write access to the session. Shared-secret-only pairings can still send idle messages and queue follow-ups.
