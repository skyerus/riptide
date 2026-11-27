"""Give a paired Codex App Server chat access to Chrome through Hermes computer use."""

import argparse
from contextlib import nullcontext, redirect_stdout
from importlib import import_module
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from hermes_chrome_profile import shared_browser
from hermes_screen import BrowserWindow, ScreenError
from mcp_stdio import MCPServer, ToolContent

SERVER = "riptide_hermes_browser"
HANDOFF = "Browser handoff complete"
INPUT_ACTIONS = {"click", "scroll", "type", "key"}
INPUT_FIELDS = {"action", "element", "coordinate", "direction", "amount", "text", "keys"}


def connector(python, source, home):
    return {"name": SERVER, "command": str(python), "args": [str(Path(__file__).resolve()),
            "--hermes-source", str(source), "--profile", str(home)], "env": []}


def tool_definitions(schema):
    properties = schema["parameters"]["properties"]
    input_properties = {key: value for key, value in properties.items() if key in INPUT_FIELDS}
    input_properties["action"] = {**properties["action"], "enum": sorted(INPUT_ACTIONS)}
    return [
        {"name": "computer_use",
         "description": "Use action=status before sign-in or when the user names a Chrome profile. "
         "It reports whether this chat is routed to its own Hermes desktop or to an explicitly shared "
         "desktop, without opening Chrome. Confirm the Chrome profile independently before navigating. "
         "Use action=capture for a fresh view before chrome_input and chrome_handoff for manual steps.",
         "inputSchema": {"type": "object", "properties": {
             "action": {**properties["action"], "enum": ["status", "capture"]}, "mode": properties["mode"],
         }, "required": ["action"], "additionalProperties": False}},
        {"name": "chrome_input",
         "description": "Click, scroll, type or send a foreground key to the paired Chrome window after a fresh capture. "
         "Use Chrome's address bar for navigation. Use chrome_handoff for credentials, payment, verification "
         "or steps that require the user.",
         "inputSchema": {"type": "object", "properties": input_properties, "required": ["action"],
                         "additionalProperties": False}},
        {"name": "chrome_handoff",
         "description": "Pause and give the user the same Chrome window in Riptide. Wait for Hand back.",
         "inputSchema": {"type": "object", "properties": {"reason": {"type": "string", "maxLength": 120}},
                         "required": ["reason"], "additionalProperties": False}},
    ]


def ask_handoff(elicit, message):
    if elicit is None:
        return False
    reply = elicit({"mode": "form", "message": message,
                   "requestedSchema": {"type": "object", "properties": {
                       "browser": {"type": "string", "enum": [HANDOFF]},
                   }}}) or {}
    return reply.get("action") == "accept" and reply.get("content") == {"browser": HANDOFF}


def tool_result(result):
    if isinstance(result, str):
        return json.loads(result)
    if not result.get("_multimodal"):
        return result
    content = []
    for block in result["content"]:
        if block["type"] == "text":
            content.append(block)
        elif block["type"] == "image_url":
            header, _, data = block["image_url"]["url"].partition(",")
            mime = header.removeprefix("data:").removesuffix(";base64")
            if mime in {"image/png", "image/jpeg", "image/webp"} and data:
                content.append({"type": "image", "mimeType": mime, "data": data})
    return ToolContent(content)


class HumanControl(ScreenError):
    pass


class Chrome:
    def __init__(self, home, lease, desktop, placement, native, *, codex_reviewed_input=False, shared=None,
                 paired_home=None):
        self.home = home
        self.lease = lease
        self.desktop = desktop
        self.placement = placement
        self.native = native
        self.codex_reviewed_input = codex_reviewed_input
        self.shared = shared
        self.paired_home = paired_home
        self.captured = None

    def route_status(self):
        requested = shared_browser(self.paired_home) if self.paired_home is not None else self.shared
        if requested != self.shared:
            return {"status": "reconnect_required",
                    "scope": "shared" if requested else "isolated",
                    "message": "The sharing policy changed. Reconnect this chat before using Chrome."}
        return {"status": "ready", "scope": "shared" if self.shared else "isolated",
                "paired_profile": profile_slug(self.paired_home or self.home),
                "desktop_profile": profile_slug(self.home)}

    def epoch(self):
        current = self.lease.get(str(self.home))
        if current.holder != self.lease.AGENT:
            raise HumanControl("The user has control of Chrome. Wait for handback.")
        return current.epoch

    def window(self, epoch, *, open_or_activate, fit_capture=False):
        if self.placement.resolve().where != self.placement.GATEWAY:
            raise ScreenError("Chrome computer use requires the paired Hermes gateway desktop.")
        self.desktop.ensure_started_for_tool()
        view = self.desktop.status()
        window = BrowserWindow({"placement": "gateway", "display": view.display, "socket": view.socket}, self.home)
        if window.env is None:
            raise ScreenError("Open Hermes browser in Riptide to start the paired desktop.")
        if self.epoch() != epoch:
            raise ScreenError("Chrome control changed. Capture it again after handback.")
        if open_or_activate:
            window.open_or_activate()
        deadline = time.monotonic() + 8
        fitting = set()
        while self.epoch() == epoch:
            if active := window.active_browser(activate=open_or_activate):
                window_id = active[0]
                if pid := window.process_id(window_id):
                    if not fit_capture or window.capture_fits(window_id):
                        return (view.display, window_id, pid)
                    if window_id not in fitting:
                        if self.epoch() != epoch:
                            break
                        if not window.set_state(window_id, window.STATES, enable=True):
                            raise ScreenError("Could not fit Chrome within the Hermes desktop for capture.")
                        fitting.add(window_id)
            if not open_or_activate or time.monotonic() >= deadline:
                break
            time.sleep(0.1)
        if fitting and self.epoch() == epoch:
            raise ScreenError("Chrome is partly outside the Hermes desktop. Open Hermes browser and fit the window.")
        raise ScreenError("Chrome is no longer in front. Capture it again before sending input.")

    def call(self, name, args, elicit):
        try:
            if name == "computer_use" and args == {"action": "status"}:
                return self.route_status()
            if self.route_status()["status"] != "ready":
                self.captured = None
                return {"error": "Chrome sharing changed. Reconnect this chat before using Chrome.",
                        "code": "browser_route_changed"}
            with redirect_stdout(sys.stderr), (self.shared.turn() if self.shared else nullcontext()) as turn:
                return self.perform(name, args, elicit, turn=turn)
        except HumanControl as error:
            return {"error": str(error), "code": "human_has_control"}
        except BlockingIOError:
            return {"error": "Another agent is using shared Chrome. Capture it again when the browser is available."}
        except ScreenError as error:
            return {"error": str(error)}
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
            return {"error": "Could not use the paired Chrome window. Open Hermes browser and retry."}

    def perform(self, name, args, elicit, *, turn=None):
        if not isinstance(args, dict):
            return {"error": "Invalid Chrome tool arguments."}
        epoch = self.epoch()
        if name == "chrome_handoff":
            reason = args.get("reason")
            if set(args) != {"reason"} or not isinstance(reason, str) or not 0 < len(reason) <= 120:
                return {"error": "Provide a short description of the manual step."}
            self.captured = None
            self.window(epoch, open_or_activate=True)
            if not ask_handoff(elicit, f"{reason.strip()} Open Hermes browser, then tap Hand back."):
                return {"status": "cancelled"}
            if self.epoch() <= epoch:
                return {"error": "Chrome was not handed back. Ask the user to take over and tap Hand back."}
            return {"status": "handed_back"}

        action = args.get("action")
        capture = name == "computer_use" and action == "capture" and args.keys() <= {"action", "mode"}
        if not capture:
            if (name != "chrome_input" or not isinstance(action, str) or action not in INPUT_ACTIONS
                    or not args.keys() <= INPUT_FIELDS):
                return {"error": "Invalid Chrome action or fields. Use computer_use to capture and chrome_input to act."}
            if not self.codex_reviewed_input:
                return {"error": "Chrome input requires the paired Codex App Server approval route."}
        target = self.window(epoch, open_or_activate=capture, fit_capture=capture)
        was_captured, self.captured = self.captured, None
        previous_turn = None if turn is None else turn - 1
        if not capture and was_captured != (epoch, target, previous_turn):
            return {"error": "Capture the Chrome window again before sending input."}
        _, window_id, pid = target

        def approve(_target, _description, **_scopes):
            # Codex has reviewed the input before dispatch. Still check the native target and lease
            # at the driver boundary in case focus or control changed after the capture.
            still_targeted = not capture and self.epoch() == epoch and self.window(
                epoch, open_or_activate=False) == target
            return "once" if still_targeted else "deny"

        self.native.set_approval_callback(approve)
        try:
            if self.epoch() != epoch:
                raise ScreenError("Chrome control changed. Capture it again after handback.")
            payload = {**args, "app": "chrome"}
            if capture:
                payload.update(mode=args.get("mode", "vision"), pid=pid, window_id=window_id)
            else:
                # Linux Chromium filters background synthetic input. The lease and window checks
                # keep foreground delivery on this profile's active browser.
                payload["delivery_mode"] = "foreground"
            result = tool_result(self.native.handle_computer_use(payload, session_id=SERVER))
        finally:
            self.native.set_approval_callback(None)
        if self.epoch() != epoch:
            raise ScreenError("Chrome control changed. Capture it again after handback.")
        if capture and (isinstance(result, ToolContent) or "error" not in result):
            self.captured = (epoch, target, turn)
        return result


def profile_slug(home):
    home = Path(home)
    return home.name if home.parent.name == "profiles" else "default"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hermes-source", type=Path, required=True)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--codex-reviewed-input", action="store_true")
    args = parser.parse_args()
    if not all(path.is_absolute() and path.is_dir() for path in (args.hermes_source, args.profile)):
        parser.error("Use the installed Hermes source and the paired profile’s absolute paths.")
    shared = shared_browser(args.profile)
    home = shared.home if shared else args.profile
    os.environ.update(HERMES_HOME=str(home), HERMES_INTERACTIVE="1", RIPTIDE_CODEX_COMPUTER_USE="1")
    sys.path.insert(0, str(args.hermes_source))
    writer = sys.stdout.buffer
    with redirect_stdout(sys.stderr):
        lease = import_module("tools.bot_desktop.lease")
        desktop = import_module("tools.bot_desktop.runtime")
        placement = import_module("tools.bot_desktop.placement")
        native = import_module("tools.computer_use.tool")
        schema = import_module("tools.computer_use.schema").COMPUTER_USE_SCHEMA
    chrome = Chrome(home, lease, desktop, placement, native,
                    codex_reviewed_input=args.codex_reviewed_input, shared=shared, paired_home=args.profile)
    MCPServer(SERVER, tool_definitions(schema), chrome.call, sys.stdin.buffer, writer).serve()


if __name__ == "__main__":
    main()
