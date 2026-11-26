---
name: riptide-browser-handoff
description: Browse in the shared Hermes Chrome window and hand it to the user for sign-in, verification, or other manual steps.
---

# Chrome handoff

Use the paired `computer_use` tool to capture and operate Chrome on the Hermes desktop. Use Chrome’s address bar to navigate, and capture the window again before acting on its new state.

When a task reaches a password, two-factor code, or other manual step, use `chrome_handoff` in Riptide. Name the site and the step. The user can select **Open Hermes browser**, tap **Take over**, complete the step in Chrome, and tap **Hand back**. Wait for the result, then capture the same window and continue. If the handoff is cancelled, report where you stopped.

The user enters credentials directly in Chrome. Keep credentials out of chat, tool inputs, and stored notes.
