---
name: riptide-browser-handoff
description: Browse in the shared Hermes Chrome window and hand it to the user for sign-in, verification, or other manual steps.
---

# Chrome handoff

## Check the route before opening a sign-in page

Riptide can route multiple Hermes agents to one existing Chrome desktop.
The host owner can allow individual profiles or opt into sharing with the
trusted targets in the Riptide pairing manifest. A shared route grants access
to the owner's desktop and its signed-in Chrome sessions.

1. Call `computer_use(action="status")` before capture. `shared` means this
   chat reaches the configured owner's desktop. `isolated` means it reaches
   the paired agent's desktop. If `shared_desktop_configured` is true and the
   route is isolated, tell the user shared Chrome exists and access for this
   pairing depends on the host policy. If the status says `reconnect_required`,
   wait for a fresh connector and recheck before sending browser input.
2. On older connectors without `status`, use an authorized read-only host
   check of `riptide-shared-browser.json` in the root Hermes home. Compare the
   current agent slug with the explicit `members` and any configured
   `pairing_manifest`, then verify the live connector's route. If you can't
   verify the route, say so. A blank window only describes the current
   desktop. The host owner controls changes to sharing policy.
3. Verify the requested Chrome profile on that desktop before navigating.
   The Chrome profile and the signed-in website account are separate checks.

Capture the paired Chrome window with `computer_use` and act on it with `chrome_input`. Use Chrome’s address bar to navigate. Capture a fresh view before every input. Chrome input uses the Codex approval reviewer.

When a task reaches a password, two-factor code, or other manual step, use `chrome_handoff` in Riptide. Name the site and the step. The user can select **Open Hermes browser**, tap **Take over**, complete the step in Chrome, and tap **Hand back**. Wait for the result, then capture the same window and continue. If the handoff is cancelled, report where you stopped.

The user enters credentials directly in Chrome. Keep credentials out of chat, tool inputs, and stored notes.
