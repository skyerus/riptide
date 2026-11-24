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

## Switch and triage

- Tap a workspace on the rail to resume its most recent chat. In ACP chats you can also swipe left on the title to move to the next workspace. **Switch** (or **⌘K**) puts live and recent chats above the full roster. Type a workspace and chat term together to search across connected workspaces, including chats you haven’t opened in Riptide. Search reads a bounded catalog, not message text. Long-press **Switch** for the previous workspace, or pin a paired workspace from its context menu. Drafts stay in memory when switching; they aren’t written to the host.
- **Inbox** separates approvals and input from missed replies and chats marked **Save to Inbox**. The tray beside the workspace rail opens it in one tap when something is waiting. A chat appears once under its highest-priority item; its saved follow-up stays saved after an approval clears. Search by workspace, chat title, or attention reason and tap to open that exact chat. Here, a connector is a paired Codex or ACP workspace, not an automatically integrated Slack or email account. The private relay can also supply attention events.
- Follow streamed text, plans, tool activity, and approval state without leaving the chat. Codex shows App Server commentary, command output, tool updates, changes, and supported structured questions. The activity disclosure keeps logs out of the main reading flow. Scroll back freely, switch workspaces without losing your place, and tap **Latest** to return to the live edge.
- Riptide retains opened Codex chat connections while you switch, so the same turn can keep streaming and ask for approval. It retires older idle connections, not active turns or unanswered requests. Codex attention also uses account-scoped App Server status and verifies completed replies before adding them. ACP approvals are shown only when Riptide observes the owning connection. A host can publish its own attention events; ACP does not itself guarantee a cross-session or background event feed.

## Desktop-aware notifications

Choose **Inbox → bell → When I’m away**. Riptide holds alerts only for the workspace with a fresh desktop-active signal. Other workspaces still alert. The companion checks whether a selected app is frontmost and the Mac has recent input; it sends the configured workspace ID and a Boolean, not app names, input events, or activity history. Phone alerts are generic and carry no chat titles or message text.

**With no relay** the Inbox still works for connected agents. Local alerts apply only to events Riptide can observe while iOS is letting it run. For alerts while Riptide is suspended, use a push-provisioned build and a private relay that receives host-side events. Nothing is hosted or set up automatically.

1. On a trusted host make two distinct random token files (mode `0600`): a client pairing token and a publisher token. Run `python Host/attention_relay.py --client-token-file <client-file> --publisher-token-file <publisher-file>`. It binds to loopback on port `8766`. Put a certificate-validated HTTPS origin on your own private network in front of it. Enter the client token in Riptide’s notification settings; it goes into Keychain.
2. On the Mac, build the helper with `swiftc -parse-as-library Host/desktop_presence.swift -o desktop-presence`. Run `./desktop-presence https://<private-relay> <publisher-token-file> <workspace-id> <desktop-app-bundle-id>` in the desktop user’s session. Copy the workspace ID from the paired agent’s context menu. Use one reporter per workspace and supply additional bundle IDs only for apps that work on that same workspace. The reporter does not infer the account or open conversation from the frontmost app. Stop the helper to stop reporting presence.
3. To enable suspended delivery, install `Host/attention-requirements.txt` and run the relay with `--apns-key-file`, `--apns-key-id`, `--apns-team`, `--apns-topic` (the app bundle identifier), and `--device-file` (inside a mode-`0700` directory). Sign the iPhone build with a push-enabled Apple profile and set `CODE_SIGN_ENTITLEMENTS=App/RiptidePush.entitlements` and `RIPTIDE_PUSH_ENVIRONMENT=development` (or `production` to match signing). Test on a real device before relying on suspended delivery.
4. `Host/codex_attention.py --help` documents the optional read-only Codex publisher. It monitors a single signed-in account and workspace via the existing private App Server connection; give it the Riptide workspace ID from the paired agent’s context menu. Other connectors may authenticate with the publisher token and POST `workspace`, `chat`, `eventID`, `reason` (`approval`, `input`, or `reply`), and `state` (`active` or `resolved`) to `/v1/events`. Use the existing paired workspace ID and backend chat ID. The relay takes no message body, and the App Server publisher does not issue turns or approvals.

The relay holds alerts while the desktop is active and gives brief app switches a 12-second grace period. Run the relay on an always-on host if you want alerts when the Mac sleeps. Publishers must reuse the same event ID when resolving a request. This prevents late or retried updates from clearing a replacement request or re-alerting for one you already answered. The relay stores only private device registration and policy on disk; its event queue and presence are temporary. APNs receives a generic alert and opaque routing identifiers. Never use a shared public relay or put pairing tokens or signing keys in the repository.

For local UX testing, the simulator suite can seed 14 workspaces, 288 extra chats, and 12 concurrently waiting approvals. For the live-turn switching test, run `Host/ux_codex_fixture.py` with the bridge dependencies and a temporary `--port-file`, then pass the port to `xcodebuild` as `TEST_RUNNER_RIPTIDE_UX_FIXTURE_PORT`. That fixture is loopback-only and needs no real account.

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
