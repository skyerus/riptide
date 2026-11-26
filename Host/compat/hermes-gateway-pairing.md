# Riptide tools in gateway-managed Hermes chats

The Riptide SSH release attaches the configured pairing, agent display name, and Chrome tools to the trusted ACP connection. The gateway forwards those tools to the chat’s Codex App Server and brings a tool’s consent or handoff form back to the same chat. Chrome access requires an exact match to the chat’s Hermes profile.

The patches target Hermes revision `8fc0374447313e276f6b9a2764bfc750190c966a`. On a clean checkout of that revision, run:

```sh
git apply --check /absolute/riptide/Host/compat/hermes-gateway-pairing.patch /absolute/riptide/Host/compat/hermes-native-chrome.patch
git apply /absolute/riptide/Host/compat/hermes-gateway-pairing.patch /absolute/riptide/Host/compat/hermes-native-chrome.patch
```

For hosts running the earlier Riptide Safari, pairing, agent-name and draft VPS Chrome patches together, apply `hermes-gateway-retire-safari.patch` and `hermes-native-chrome.patch` in place. For other combinations, reverse the installed versions of the connector patches and apply the consolidated pairing patch. Check each patch with `git apply --check` first.

Stage the matching Riptide Host release, configure the trusted pairing and reconnect after reloading the gateway. For installed Safari connectors, update all affected SSH keys to remove their legacy options, restore the real Codex binary and remove the obsolete MCP entries before retiring the relay services. Keep the previous versioned release and config backups for rollback.
