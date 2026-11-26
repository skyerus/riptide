# Riptide pairing in gateway-managed Hermes chats

The Riptide SSH release attaches a standard MCP stdio server when the device's forced command has `--pairing-config`. Hermes' native runtime uses the gateway's existing tool and form handling. The Codex App Server adapter forwards the same scoped server and presents its pairing form through the live ACP approval channel. Both routes use the **Connect agent** card available since iOS build 15.

The Codex runtime must allow interactive MCP form requests. The adapter targets Hermes `8fc0374447313e276f6b9a2764bfc750190c966a` and applies on top of [the existing Safari gateway patch](hermes-gateway-safari.md). With the Safari patch present, verify and apply the pairing patch from the Hermes checkout.

```sh
git apply --check /absolute/riptide/Host/compat/hermes-gateway-pairing.patch
git apply /absolute/riptide/Host/compat/hermes-gateway-pairing.patch
```

Stage the matching Riptide Host release and use `Host/update_ssh_release.py` with the paired key's existing manifest. Reload the Hermes gateway and reopen the Riptide chat after its current turn finishes so Hermes can bind the refreshed tools. Ask to connect a configured profile in each runtime, and check that Skip leaves the profile unpaired and that Connect agent opens its main chat from Agents.

To roll back, restore the prior SSH release, reverse the pairing patch with `git apply -R` and reload the gateway.
