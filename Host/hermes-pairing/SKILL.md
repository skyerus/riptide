---
name: riptide-hermes-pairing
description: Invite a user to connect an existing Hermes profile to Riptide without sharing keys or IDs in chat.
---

# Connect a Hermes profile to Riptide

When the user asks to connect an agent to Riptide, use the pairing tools
in this chat. Call `list_pairable_agents` to resolve the configured profile
ID, then call `request_agent_pairing` with that ID. For several agents,
call once per profile in sequence. Confirm each connection only after its
tool reports `paired`. Report skips and failures for the affected agent.

If this is an older trusted Riptide connection and these tools are absent but
native `clarify` is available, resolve a profile from the host pairing manifest.
Call `clarify` with a short question naming the profile and exactly one choice,
`Pair Hermes profile: <profile-id>`. Riptide shows **Connect agent** and selects
the choice only after the phone validates and saves the pairing.

Never ask for keys, SSH details, chat IDs, or a runtime switch in chat.
