# Safari with Hermes gateway-managed Codex

Some Hermes installations run ACP as a viewer. The persistent gateway owns the chat and starts Codex with its own environment. Configure `--safari-mcp-python` in the Riptide SSH forced command as documented in [the Riptide README](../../README.md#safari-handoff-through-mcp).

The compatibility patch is for Hermes commit `8fc0374447313e276f6b9a2764bfc750190c966a`. It forwards only the discovered `riptide_safari` stdio connector from the gateway's frozen editor MCP configuration to that chat's Codex process. It reopens the existing Codex thread when only the connector changes.

From the clean Hermes checkout at that revision, run the following using the absolute path to the patch from your Riptide checkout.

```sh
git apply --check /path/to/riptide/Host/compat/hermes-gateway-safari.patch
git apply /path/to/riptide/Host/compat/hermes-gateway-safari.patch
```

Gracefully reload the Hermes gateway, then reopen the Riptide chat to attach its connector. To roll back, use `git apply -R` with the same patch and reload the gateway again. Recheck compatibility before updating Hermes.
