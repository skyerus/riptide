# Codex Chrome on Hermes Bot Screen

This connector runs on the gateway host. It opens the paired profile's existing Chrome through the same launcher as Bot Screen. It checks the browser process against the window on that screen. Each page action checks the profile's native control lease. Codex can list tabs, open a site, read visible content, click controls, and fill ordinary fields. Chrome handoff uses the current chat's approval card so the user can sign in and hand back the same tab.

The adapter targets Hermes `8fc0374447313e276f6b9a2764bfc750190c966a` with the [Safari](hermes-gateway-safari.md), [pairing](hermes-gateway-pairing.md), and [agent profile](hermes-gateway-agent-profile.patch) adapters applied. From the installed Hermes checkout, run `git apply --check` on [the Chrome gateway patch](hermes-gateway-browser-mcp.patch), then apply it and reload the gateway. Keep the profile's existing `browser.headed` and Bot Screen setup. Use Python from the installed Hermes environment.

Stage the exact Riptide release and run the existing SSH release updater for each pairing that already has `--hermes-screen`. Pass the new `--hermes-browser-mcp` option with the two absolute paths.

```sh
python3 -B Host/update_ssh_release.py --fingerprint 'SHA256:…' \
  --releases-dir /absolute/riptide/releases \
  --previous "$previous_sha" --revision "$release_sha" \
  --hermes-browser-mcp /absolute/hermes/python /absolute/hermes/source
```

Install the release's `Host/hermes-browser-handoff/SKILL.md` in each enabled profile's `skills/riptide-browser-handoff/` directory. Reopen the chat to discover its connector. Test a new tab and an explicit handoff on a fixture page before using it with a signed-in site.
