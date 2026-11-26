# Riptide project instructions

## Chat intent

- Never infer user intent or trigger a workflow by matching words or phrases in chat messages. Pass natural-language messages to the agent and handle its decisions through structured tool calls or protocol events. Require explicit UI actions for consent where the app must verify it independently.

## Cross-runtime features

- Design user-facing agent features to be harness- and agent-agnostic. Put the workflow, consent, and result in a shared structured contract. Use runtime adapters for transport and capability discovery, and verify the complete workflow on each supported route before calling it done.

## UI changes

- Prefer native iOS controls, pickers, and presentation styles wherever they meet the feature’s needs. Keep system defaults for appearance, navigation, and dismissal where possible.
- Use the shared `ChatComposer` and model controls for Codex, Hermes, OpenClaw, and any new agent. Keep model, intelligence, Fast mode, dictation, and send/stop consistent wherever the backend supports them. Each connector must read capabilities and apply settings through its native protocol for the selected chat.
- Keep the context window ring visible in every chat composer. Show usage reported by the backend and an unavailable state when there are no usage figures.
- For every user-visible UI change, run the updated app on an iPhone simulator or device, capture the changed screens or states, and include the screenshots in the final reply. Attach or embed the images; a description or local path alone is not enough.
- Use fixture or sanitized data in screenshots. Keep captures out of Git unless requested. If capture is blocked, say why rather than substituting a mockup for the running app.

## VPS changes

- Make every Riptide VPS runtime, configuration, and deployment change reproducible from this repository. Commit the implementation, deployment automation, or configuration templates before applying them. Use the versioned deployment path so a fresh VPS can reproduce the setup without manual edits or dashboard clicks.
