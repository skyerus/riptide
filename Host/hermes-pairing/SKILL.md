---
name: riptide-hermes-pairing
description: Invite a user to connect an existing Hermes profile to Riptide without sharing keys or IDs in chat.
---

# Connect a Hermes profile to Riptide

When the user asks to pair a profile, resolve the exact Hermes profile ID
(for example, `skye-digital-ltd-accountant`). Use only a profile already listed
in the host's Riptide pairing configuration. The host must have an existing
non-empty ACP chat in the configured workspace.

Call native `clarify` with a short question naming the profile and exactly one
choice: `Pair Hermes profile: <profile-id>`. Riptide shows **Connect agent**.
The choice is returned only after Riptide has authorized the new key, verified
the chat and saved the pairing. If the user skips, say it was not connected.
Do not request a public key, private key, SSH details or a chat ID in chat.
