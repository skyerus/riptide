# Riptide

A native iPhone client for agents you already run. Tap an agent to return to its main chat; open **Chats** to start or revisit a separate conversation without disturbing the main one.

## Run the demo

Requires Xcode with a Swift 6.2-or-newer toolchain, an iOS 18-or-newer simulator, XcodeGen, and Node.js for building the bundled renderers.

```sh
npm ci --prefix Rendering
npm run build --prefix Rendering
xcodegen generate
open Riptide.xcodeproj
```

Run the **Riptide** scheme. The OpenClaw and Hermes agents are local fixtures, not provisioned agents. Tap an agent to open Main Chat. Tap the chat title to open saved chats or start another, and use **Edit** on the roster to pin, reorder, or switch to a list.

The composer’s model picker and context ring show session-specific settings and simulated usage from the demo backend. Send any text to see a streamed reply, tool status and a Markdown table; include `approval` to try the permission card. Chats and their settings stay in the app’s local fixture store across relaunches.

`swift test` runs the ACP fixture and session tests. Xcode's **Product → Test** also runs the simulator flow.

## Rich replies

Send `formatting demo` to a fixture agent for streamed Markdown, a Mermaid diagram, syntax-highlighted code, and a numbered diff. The live Codex screen uses the same renderer and displays native turn diffs under **Changes**.

The formatting follows [Codex’s open-source streaming](https://github.com/openai/codex/blob/573bc548464aeef750d464e7cc33c15ddf5907fe/codex-rs/tui/src/markdown_stream.rs) and [fence rules](https://github.com/openai/codex/blob/573bc548464aeef750d464e7cc33c15ddf5907fe/codex-rs/tui/src/markdown_render/mermaid.rs): format complete lines and wait for a real closing fence before rendering a diagram. Riptide uses SwiftUI, Mermaid, and Highlight.js rather than embedding Codex’s terminal UI. Both renderer libraries ship in the app and work offline; diagram config overrides are disabled, external navigation is blocked, and invalid diagrams retain their copyable source. ChatGPT’s interactive Visualizations artifacts are a separate feature and are not supported.

## Backend boundary

`ACPClient` speaks ACP v1 JSON-RPC for initialization, session creation/listing/replay, prompts, cancellation and permission replies. The composer reads session configuration and usage events and only displays controls the backend reports. Its `ACPTransport` exchanges complete JSON-RPC messages; the demo implements the other end of that interface in process. Private remotes use certificate-validated WebSockets. The app does not ship live host settings, credentials or a hosted relay.

Agent targets explicitly map to their backend's existing main session. Pairing checks that the backend lists that session in the selected workspace and advertises history replay. A missing main session is an error, not an instruction to create a replacement. On reconnect Riptide loads the same ID; the backend remains responsible for replay and for reissuing any pending approval. A request ID from a closed connection is never reused.

## Pair private remotes

Use **+ → Pair remote** on the agent roster. Provide a name, private `wss://` endpoint, absolute workspace on the host, and the endpoint’s capability token. Both ACP backends also require an existing main session ID. The token is not an OpenAI key: it stays in this device’s Keychain. Codex pairing binds the endpoint to the signed-in ChatGPT account/workspace; re-pair if that identity changes.

- **Codex:** Keep an explicitly authenticated App Server WebSocket on host loopback behind a TLS proxy reachable only on your private network. Use the server’s capability-token mode; do not expose the app server to the internet. In the app, reopen a saved chat or make a new one. Reconnect rejoins by ID, loads up to the latest 30 turns, and displays approvals the server sends for that chat. Simple command approvals offer Allow once and Decline; review broader requests in native Codex.
- **Hermes or OpenClaw:** Run the backend's supported ACP stdio command on your own host. `Host/acp_bridge.py` exposes one JSON-RPC object per WebSocket text frame on loopback `/acp`; it stores no transcripts and does not replace either backend. Install `Host/requirements.txt`, create a strong per-endpoint bearer in a mode-0600 file, and run `python Host/acp_bridge.py --token-file /path/to/token -- hermes acp` or the equivalent `openclaw acp` command. Put this listener behind your own private TLS proxy and forward the Authorization header. Run it under a least-privilege account; do not use a public ingress. Test `session/list`, `session/load`, and a one-time approval on the actual backend version. The stdio child closes on disconnect; only approvals the backend reissues on load can appear again. See [Hermes ACP internals](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/developer-guide/acp-internals.md) and [OpenClaw ACP compatibility](https://docs.openclaw.ai/cli/acp).

## Local Codex handoff proof

The debug build can also talk directly to a native Codex App Server on the same Mac. This proof path requires an explicit loopback WebSocket URL, a bearer token, and an absolute disposable workspace, supplied at launch as `RIPTIDE_CODEX_URL`, `RIPTIDE_CODEX_BEARER`, and `RIPTIDE_CODEX_WORKSPACE`. Use the `SIMCTL_CHILD_` prefix with `simctl launch`. Keep the listener on `127.0.0.1`, require capability-token authentication, and never put the token in the repo.

Start a read-only test turn in the official Codex terminal UI connected to that server with `codex --remote`. While it is running, open **Codex on this Mac** in Riptide. The app joins the one active chat in that exact workspace, displays live output, and sends **Steer** against the existing turn ID. It does not create turns or answer approvals. This is a local simulator proof, not ChatGPT Remote pairing or a general network connection feature.

The opt-in `CodexLiveUITests` flow expects a private directory containing the token file `bearer` and the disposable workspace `proof`. Set `TEST_RUNNER_RIPTIDE_CODEX_PROOF_DIR` to that directory and `TEST_RUNNER_RIPTIDE_CODEX_URL` to the loopback URL when running the test via `xcodebuild`. Start a terminal turn that emits progress for about two minutes and follows any later steering instruction. The test waits for fresh output, sends a marker, and verifies that the same turn returns it. Without the opt-in settings, the test is skipped.

## Codex subscription voice

Riptide uses the host's existing ChatGPT sign-in and refuses API-key accounts. It negotiates the experimental Codex App Server WebRTC route; media goes directly between the phone and the voice service. Tap the phone icon from the Codex chat list for a separate, ephemeral, read-only call. Tap it inside a saved chat to speak with that exact thread and its context, without replacing the chat connection or changing host permissions. On the **Codex on this Mac** debug screen, **Saved chats** exposes the same flow. Calls are outgoing and foreground-only.

Use an App Server build with realtime v3 WebRTC support and a ChatGPT account with Codex voice access. The opt-in simulator test above also checks that WebRTC connects and closes with microphone access disabled. Test actual capture and playback on an iPhone before relying on the call.

## Hermes and OpenClaw voice

Pair the agent's ACP chat first. The phone button calls in the open chat; long-press it for **New voice chat** or **Voice settings**. Voice connects separately to the backend's native WebRTC endpoint. Enter the endpoints and tokens in the app, not in the repo. Voice endpoints need trusted TLS and must use the same hostname as the chat endpoint; they can use a different port.

- **Hermes Talk (ChatGPT subscription):** Install a compatible [Hermes Talk](https://github.com/TheSmokeDev/hermes-talk/blob/55ae7b29082faf5aaebac7cb7d692c3c2f8ade4f/docs/GPT-LIVE.md) plugin and Hermes host with Dashboard task context and canonical task support. Use the Dashboard for your existing Hermes profile, with `TALK_VOICE_MODE=live` and `TALK_LIVE_AUTH=subscription` fixed for the service lifetime. Sign into Codex on that host as the account running the plugin. Don’t configure API billing or proxy the same URL to mixed billing modes. In Riptide choose **Talk · ChatGPT subscription** and enter the Dashboard HTTPS origin and session token, the named Hermes profile if applicable, and the optional Talk route token. The same local profile must back both voice and ACP; the selected ACP session ID must already exist in Talk's authorized task catalog.
- **Hermes built-in GPT-Live (API billing):** This separate, explicitly selected route uses the [Hermes built-in voice API](https://hermes-agent.nousresearch.com/docs/user-guide/features/voice-mode). The host provisions its voice provider. Riptide seeds the call from the open chat and routes delegated requests back into its ACP session with existing approvals. No provider key goes on the phone.
- **OpenClaw:** Use a Gateway and voice provider that support [gateway-controlled WebRTC Talk](https://docs.openclaw.ai/gateway/protocol/transport#gateway-controlled-webrtc-talk). Enter the private Gateway `wss://` endpoint and its pairing credential. If prompted, approve the exact device request on the Gateway and retry; Riptide saves the device's scoped `operator.talk` token instead of the shared credential. The Gateway owns voice turns and their approvals. The ACP host must report the selected chat's Gateway session key. A new voice chat starts only if the host confirms a distinct key.

For Talk, Riptide checks the configured OAuth subscription lane before opening WebRTC and never retries via an API route. The plugin owns audio-side delegation, task permissions, and persistence; phone calls do not translate Talk events into ACP prompts or approve work. Ending a call releases the audio/task binding, not already accepted work. Riptide reloads the selected chat through ACP to pick up saved history. Pairing tests readiness, not entitlement or two-way audio. After pairing, start a call on a real iPhone, confirm audio and a harmless request in that exact chat, and verify any host-managed approval separately.

Calls are outgoing and foreground-only. Neither Hermes route changes direct Codex's App Server subscription-only authentication or OpenClaw Talk.
