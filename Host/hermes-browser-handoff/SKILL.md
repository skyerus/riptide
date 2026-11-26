---
name: riptide-browser-handoff
description: Browse in the shared Hermes Chrome window and hand it to the user for sign-in, verification, or other manual steps.
---

# Chrome handoff

Capture the paired Chrome window with `computer_use` and act on it with `chrome_input`. Use Chrome’s address bar to navigate. Capture a fresh view before every input. Chrome input uses the Codex approval reviewer.

When a task reaches a password, two-factor code, or other manual step, use `chrome_handoff` in Riptide. Name the site and the step. The user can select **Open Hermes browser**, tap **Take over**, complete the step in Chrome, and tap **Hand back**. Wait for the result, then capture the same window and continue. If the handoff is cancelled, report where you stopped.

The user enters credentials directly in Chrome. Keep credentials out of chat, tool inputs, and stored notes.
