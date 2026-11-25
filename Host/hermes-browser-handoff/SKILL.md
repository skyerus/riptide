---
name: riptide-browser-handoff
description: Give the user temporary control of the current Hermes browser when they ask to sign in or a browser task reaches a login or two-factor step.
---

# Browser handoff

Use the native Hermes browser tool to open the requested site's genuine sign-in page in the current profile's headed browser. Keep the tab open so the user and the agent work in the same browser session.

When the user is chatting from Riptide, use the native `clarify` tool with a short question naming the site and the action the user needs to complete. Supply exactly one choice, `Browser handoff complete`. Riptide shows that clarification with **Open Hermes browser** and returns the choice when the user hands back control and continues. If the clarification is skipped, report where you stopped. If `clarify` is unavailable, ask the user to choose **Open Hermes browser** in the chat actions menu and to hand back control when finished.

The user enters credentials and two-factor codes directly in the site. Keep credentials out of chat, tool inputs, and stored notes. After handback, inspect the same tab, verify the account or workspace if relevant, and continue the requested task.
