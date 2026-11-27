---
name: riptide-browser-handoff
description: Browse in the shared Hermes Chrome window and hand it to the user for sign-in, verification, or other manual steps.
---

# Chrome handoff

## Check the route before opening a sign-in page

Riptide can route multiple Hermes agents to one existing Chrome desktop. This
does **not** merge Hermes agents or their workspaces. Sharing is opt-in: new
agents stay isolated until included in the host owner's shared-browser policy.
A shared route grants the whole owner desktop, not just one Chrome profile.

1. Try `computer_use(action="status")` before capture. `shared` means this
   chat reaches the configured owner's desktop; `isolated` means it reaches
   only the paired agent's desktop. If it says `reconnect_required`, wait for
   a fresh connector and recheck before sending browser input.
2. On older connectors without `status`, use an authorized read-only host
   check of `riptide-shared-browser.json` in the root Hermes home. Compare the
   current agent slug with the explicit `members` and the live connector's
   route, not just the policy on disk. If host access is unavailable or the
   route can't be verified, say so; don't assume a blank window means the
   existing profile is missing. Never add agents to the policy implicitly.
3. Verify the requested Chrome profile on that desktop before navigating.
   The Chrome profile and the signed-in website account are separate checks.

Capture the paired Chrome window with `computer_use` and act on it with `chrome_input`. Use Chrome’s address bar to navigate. Capture a fresh view before every input. Chrome input uses the Codex approval reviewer.

When a task reaches a password, two-factor code, or other manual step, use `chrome_handoff` in Riptide. Name the site and the step. The user can select **Open Hermes browser**, tap **Take over**, complete the step in Chrome, and tap **Hand back**. Wait for the result, then capture the same window and continue. If the handoff is cancelled, report where you stopped.

The user enters credentials directly in Chrome. Keep credentials out of chat, tool inputs, and stored notes.
