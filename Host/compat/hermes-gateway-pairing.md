# Riptide tools in gateway-managed Hermes chats

The Riptide SSH release attaches the configured pairing, agent profile, and Chrome tools to the trusted ACP connection. The gateway forwards those tools to the chat’s Codex App Server and brings a tool’s consent or handoff form back to the same chat. Chrome access requires an exact match to the chat’s Hermes profile.

The patches target Hermes revision `8fc0374447313e276f6b9a2764bfc750190c966a`. On a clean checkout of that revision, run:

```sh
git apply --check /absolute/riptide/Host/compat/hermes-gateway-pairing.patch /absolute/riptide/Host/compat/hermes-native-chrome.patch /absolute/riptide/Host/compat/hermes-codex-computer-use-images.patch
git apply /absolute/riptide/Host/compat/hermes-gateway-pairing.patch /absolute/riptide/Host/compat/hermes-native-chrome.patch /absolute/riptide/Host/compat/hermes-codex-computer-use-images.patch
```

For hosts running the earlier Riptide Safari, pairing, agent-name and draft VPS Chrome patches together, apply `hermes-gateway-retire-safari.patch`, `hermes-native-chrome.patch`, `hermes-codex-computer-use-images.patch`, and `hermes-codex-chrome-input-approval.patch` in place. For other combinations, reverse the installed versions of the connector patches and apply the consolidated pairing patch. Check each patch with `git apply --check` first. A host that already runs the earlier Chrome connector only needs `hermes-codex-chrome-input-approval.patch` from this release.

For self-set profile photos, check and apply `hermes-agent-profile-photo.patch` after the pairing adapter. Reload the gateway before switching pairings to a photo-enabled host payload. Existing name-only connectors continue to work during the upgrade.

Stage the matching Riptide Host release, configure the trusted pairing and reconnect after reloading the gateway. For installed Safari connectors, update all affected SSH keys to remove their legacy options, then run `Host/deploy/retire-hermes-safari.py` using Hermes’s Python environment to restore the original Codex executable and remove the obsolete MCP entries from the affected profiles. Disable the obsolete relay services after verifying the migrated chats. Keep the previous versioned release and config backups for rollback.

Chrome input goes through the Codex App Server reviewer. Configure `approval_policy = "on-request"` and `approvals_reviewer = "auto_review"` in the gateway’s Codex configuration to use **Approve for me**. The handoff form still returns to the person in the chat.
