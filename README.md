# Riptide

A native iPhone client for agents you already run. Tap an agent to return to its main chat; open **Chats** to start or revisit a separate conversation without disturbing the main one.

## Run locally

Requires Xcode with a Swift 6.2-or-newer toolchain, an iOS 18-or-newer simulator, XcodeGen, and Node.js for building the bundled renderers.

```sh
npm ci --prefix Rendering
npm run build --prefix Rendering
xcodegen generate
open Riptide.xcodeproj
```

Run the **Riptide** scheme to connect your first agent. To try the local fixtures instead, set `RIPTIDE_DEMO=1` in the Debug scheme's Run environment. The demo opens on Inbox with sample OpenClaw and Hermes agents. In **Agents**, tap an avatar to open its Main Chat. Tap another avatar above the conversation to switch agents, or tap **Side chats** to find or start a chat with the current agent.

The composer’s model picker and context ring show session-specific settings and simulated usage from the demo backend. Send any text to see a streamed reply, tool status and a Markdown table; include `approval` to try the permission card. Chats and their settings stay in the app’s local fixture store across relaunches.

`swift test` runs the ACP fixture and session tests. Xcode's **Product → Test** also runs the simulator flow.

## UI rehearsal

[Stageshow](.agents/skills/stageshow/SKILL.md) is installed as a project skill, not an app dependency. [The native rehearsal](docs/stageshow-rehearsal.md) describes the reference scenes and the simulator checks for Inbox, workspace navigation, and streaming chat.

## Switch and triage

- **Inbox**, **Agents**, and **Groups** are the top-level tabs. Tap an agent to open its workspace, or touch and hold its avatar to choose a profile photo stored on this device. In a chat, **Switch** (or **⌘K**) finds live, recent and saved chats across workspaces. Search reads a bounded catalog, not message text. Drafts stay in memory when switching; they aren’t written to the host.
- **Inbox** separates approvals and input from missed replies and chats marked **Save to Inbox**. A chat appears once under its highest-priority item; its saved follow-up stays saved after an approval clears. Tap an item to open that exact chat. In a busy Inbox, search by workspace, chat title, or attention reason. Here, a connector is a paired Codex or ACP workspace, not an automatically integrated Slack or email account. The private relay can also supply attention events.
- Follow streamed text, plans, tool activity, and approval state without leaving the chat. Codex shows App Server commentary, command output, tool updates, changes, and supported structured questions. The transcript follows incoming text, pauses while you hold it, and stays in place if you scroll back. Switch workspaces without losing your place, or tap **Latest** to return to the live edge.
- Tap Send during a reply to steer it. If the reply has finished, the message starts a new turn. Touch and hold Send and choose **Queue** to wait for the current reply. Tap the queue count to review or remove a follow-up. The queue stays in the running app and pauses on Stop or disconnect. Hermes and OpenClaw hosts need the [ACP steering adapter](Host/compat/acp-steering.md) for live steering.
- Riptide retains opened Codex chat connections while you switch, so the same turn can keep streaming and ask for approval. It retires older idle connections, not active turns or unanswered requests. Codex attention also uses account-scoped App Server status and verifies completed replies before adding them. ACP approvals are shown only when Riptide observes the owning connection. A host can publish its own attention events; ACP does not itself guarantee a cross-session or background event feed.

## Desktop-aware notifications

Choose **Inbox → bell → When I’m away**. Riptide holds alerts only for the workspace with a fresh desktop-active signal. Other workspaces still alert. The companion checks whether a selected app is frontmost and the Mac has recent input. It sends the configured workspace ID and whether the workspace is active. Reply alerts can include the first non-empty line of the reply.

**With no relay** the Inbox still works for connected agents. Local alerts apply only to events Riptide can observe while iOS is letting it run. For alerts while Riptide is suspended, use a push-provisioned build and a private relay that receives host-side events. Nothing is hosted or set up automatically.

### Hermes over SSH

A push-enabled Riptide build can register through an existing Hermes SSH pairing. Choose **Inbox → bell → Deliver alerts → Always** or **When I’m away** and allow iOS notifications. When Riptide starts a turn, a private host service observes that chat for replies, approvals, and input requests using the existing Hermes gateway. The service keeps its subscription when the phone disconnects. An explicit HTTPS relay takes priority when one is configured in the app. The SSH relay currently treats an unreported desktop as away.

On a systemd host, stage this revision under `/usr/local/libexec/riptide/attention/releases/<full-git-sha>`. Install the pure Python dependencies in `Host/deploy/hermes-attention-http2.txt` into that release's `dependencies` directory. The other Python modules come from the installed Hermes runtime. Copy the service template and install the example configuration as `/etc/riptide-hermes-attention.conf` with the actual release paths, Hermes profile, Python interpreter, workspace, and Apple key identifiers. Run the service as the same OS account as the Hermes gateway and the restricted SSH pairing. Install the production APNs key for `app.riptide.client` as `/var/lib/riptide-hermes-attention/apns.p8` with mode `0600` in a directory with mode `0700`. Start and enable `riptide-hermes-attention.service`.

Run `Host/deploy/enable-hermes-attention.py` from that same revision with `--authorized-keys`, `--hermes`, `--releases`, `--revision`, and `--socket /var/lib/riptide-hermes-attention/attention.sock`. It checks the private relay and updates existing restricted keys that use the configured Hermes launcher. Newly approved **Connect agent** pairings inherit the relay from the trusted pairing that enrolled them. For manually paired keys, rerun the same command.

The service's `HERMES_HOME` points to the default Hermes home, which contains `profiles/` for named profiles. The relay keeps a separate set of registrations and chat subscriptions for each profile and workspace. It retains existing registrations for the default workspace. Riptide registers additional workspaces when the app comes to the foreground. Keep the key and device state outside the source tree.

### HTTPS relay

1. On a trusted host make two distinct random token files (mode `0600`): a client pairing token and a publisher token. Run `python Host/attention_relay.py --client-token-file <client-file> --publisher-token-file <publisher-file>`. It binds to loopback on port `8766`. Put a certificate-validated HTTPS origin on your own private network in front of it. Enter the client token in Riptide’s notification settings; it goes into Keychain.
2. On the Mac, build the helper with `swiftc -parse-as-library Host/desktop_presence.swift -o desktop-presence`. Run `./desktop-presence https://<private-relay> <publisher-token-file> <workspace-id> <desktop-app-bundle-id>` in the desktop user’s session. Copy the workspace ID from the paired agent’s context menu. Use one reporter per workspace and supply additional bundle IDs only for apps that work on that same workspace. The reporter does not infer the account or open conversation from the frontmost app. Stop the helper to stop reporting presence.
3. To enable suspended delivery, install `Host/attention-requirements.txt` and run the relay with `--apns-key-file`, `--apns-key-id`, `--apns-team`, `--apns-topic` (the app bundle identifier), and `--device-file` (inside a mode-`0700` directory). Sign the iPhone build with a push-enabled Apple profile and set `RIPTIDE_PUSH_ENTITLEMENTS=App/RiptidePush.entitlements` and `RIPTIDE_PUSH_ENVIRONMENT=development` (or `production` to match signing). Test on a real device before relying on suspended delivery.
4. `Host/codex_attention.py --help` documents the optional read-only Codex publisher. It monitors a single signed-in account and workspace via the existing private App Server connection. Give it the Riptide workspace ID from the paired agent’s context menu. Other connectors may authenticate with the publisher token and POST `workspace`, `chat`, `eventID`, `reason` (`approval`, `input`, or `reply`), and `state` (`active` or `resolved`) to `/v1/events`. Use the existing paired workspace ID and backend chat ID. For an active reply event, send the first non-empty line as the optional `preview` field. The relay caps it at 180 characters.

The relay holds alerts while the desktop is active and gives brief app switches a 12-second grace period. Run the relay on an always-on host if you want alerts when the Mac sleeps. Publishers must reuse the same event ID when resolving a request. This prevents late or retried updates from clearing a replacement request or re-alerting for one you already answered. The relay stores private device registration and policy on disk. Its event queue and presence are temporary. APNs receives the alert text and opaque routing identifiers. Reply alerts use the first non-empty line when available and display “Reply ready” as a fallback. Never use a shared public relay or put pairing tokens or signing keys in the repository.

For local UX testing, the simulator suite can seed 14 workspaces, 288 extra chats, and 12 concurrently waiting approvals. For the live-turn switching test, run `Host/ux_codex_fixture.py` with the bridge dependencies and a temporary `--port-file`, then pass the port to `xcodebuild` as `TEST_RUNNER_RIPTIDE_UX_FIXTURE_PORT`. That fixture is loopback-only and needs no real account.

To test successful first pairing, run the same fixture with `--tls-cert` and `--tls-key` for `127.0.0.1`, trust its development CA on a test simulator, and pass the port as `TEST_RUNNER_RIPTIDE_PAIR_FIXTURE_PORT`. Use a signed simulator build with Keychain access; the test exercises normal authenticated pairing.

The agent rename UI test uses `python Host/test_agent_profile.py --cert <localhost-cert> --key <localhost-key> --port-file <file>`. Use a certificate for `127.0.0.1` trusted by the simulator and pass the port as `TEST_RUNNER_RIPTIDE_PROFILE_FIXTURE_PORT`. Start a fresh fixture for each run.

## Rich replies

Send `formatting demo` to a fixture agent for streamed Markdown, a Mermaid diagram, syntax-highlighted code, and a numbered diff. The live Codex screen uses the same renderer and displays native turn diffs under **Changes**.

The formatting follows [Codex’s open-source streaming](https://github.com/openai/codex/blob/573bc548464aeef750d464e7cc33c15ddf5907fe/codex-rs/tui/src/markdown_stream.rs) and [fence rules](https://github.com/openai/codex/blob/573bc548464aeef750d464e7cc33c15ddf5907fe/codex-rs/tui/src/markdown_render/mermaid.rs): format complete lines and wait for a real closing fence before rendering a diagram. Riptide uses SwiftUI, Mermaid, and Highlight.js rather than embedding Codex’s terminal UI. Both renderer libraries ship in the app and work offline; diagram config overrides are disabled, external navigation is blocked, and invalid diagrams retain their copyable source. ChatGPT’s interactive Visualizations artifacts are a separate feature and are not supported.

## Backend boundary

`ACPClient` speaks ACP v1 JSON-RPC for initialization, session creation/listing/replay, prompts, cancellation and permission replies. The composer reads session configuration and usage events and only displays controls the backend reports. Its `ACPTransport` exchanges complete JSON-RPC messages; the demo implements the other end of that interface in process. Private remotes use certificate-validated WebSockets. The app does not ship live host settings, credentials or a hosted relay.

Agent targets explicitly map to their backend's existing main session. Pairing checks that the backend lists that session in the selected workspace and advertises history replay. A missing main session is an error, not an instruction to create a replacement. On reconnect Riptide loads the same ID; the backend remains responsible for replay and for reissuing any pending approval. A request ID from a closed connection is never reused.

## Pair private remotes

On first launch, choose your agent type and connect it to open Inbox. To add another agent later, use **pencil → Pair remote**. For WebSocket connections, provide a private `wss://` endpoint, the absolute workspace on the host, and the endpoint’s capability token. ACP backends also require an existing main session ID. The token is not an OpenAI key: it stays in this device’s Keychain. Codex pairing binds the endpoint to the signed-in ChatGPT account/workspace; re-pair if that identity changes.

- **Codex:** Keep an explicitly authenticated App Server WebSocket on host loopback behind a TLS proxy reachable only on your private network. Use the server’s capability-token mode; do not expose the app server to the internet. In the app, reopen a saved chat or make a new one. Reconnect rejoins by ID, loads up to the latest 30 turns, and displays approvals the server sends for that chat. Simple command approvals offer Allow once and Decline; review broader requests in native Codex.
- **Hermes or OpenClaw:** Run the backend's supported ACP stdio command on your own host. `Host/acp_bridge.py` exposes one JSON-RPC object per WebSocket text frame on loopback `/acp`; it stores no transcripts and does not replace either backend. Install `Host/requirements.txt`, create a strong per-endpoint bearer in a mode-0600 file, and run `python Host/acp_bridge.py --token-file /path/to/token -- hermes acp` or the equivalent `openclaw acp` command. Put this listener behind your own private TLS proxy and forward the Authorization header. Run it under a least-privilege account; do not use a public ingress. Test `session/list`, `session/load`, and a one-time approval on the actual backend version. The stdio child closes on disconnect; only approvals the backend reissues on load can appear again. See [Hermes ACP internals](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/developer-guide/acp-internals.md) and [OpenClaw ACP compatibility](https://docs.openclaw.ai/cli/acp).

### Chat attachments

Tap **+** in a chat to take a photo, pick from Photos, or browse Files. Use the editor’s Paste action or Command-V to attach copied files and images. Review or remove the attachments in the draft, then send them with optional text. Each message accepts up to four attachments. Attachments can steer an active Codex turn or queue for the next turn. In ACP chats, follow-ups containing attachments queue for the next turn. Hermes group attachments are staged on the paired host for the group’s agents to read by path.

Codex uses its App Server to stage attachments in the host's Codex home and sends images as vision input. The limit is 8 MB per message. ACP uses the agent's advertised image capability and a 1 MB limit. Update the Riptide SSH launcher or WebSocket bridge on the paired host to send arbitrary files. The bridge stages them in private temporary directories on that host, where the agent can read them by path until the host clears its temporary files. Older ACP connections can still attach small UTF-8 text files.

### Direct ACP over SSH

For a host you already reach by SSH, choose **SSH** in the ACP pairing form. Enter `ssh://user@host` (add a port if needed), the workspace, an existing main chat ID, and the OpenSSH SHA-256 host-key fingerprint from a trusted source. On the server you can read the Ed25519 fingerprint with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`. A change in fingerprint fails closed.

Copy the public key from Riptide and authorize it for a fixed command in the agent account’s `authorized_keys`. Install `Host/ssh_acp.py` at a trusted, non-writable path, then use a key entry such as:

```text
restrict,command="/usr/bin/python3 /usr/local/libexec/riptide/ssh_acp.py --workspace /srv/agent-workspace -- /home/agent/.local/bin/hermes-acp" ssh-ed25519 PUBLIC_KEY riptide-device
```

Use absolute paths for the regular agent account, workspace, and native ACP launcher. The key disallows SSH shell access, terminal allocation, and port forwarding. The launcher limits chat to the paired workspace and refuses client-supplied MCP servers and approval-policy changes. Use a trusted device and the least-privilege agent account available, since prompts reach the real agent with its configured tools. Removing the key on the host revokes access. The private key stays in the device’s Keychain. Voice keeps its separate native endpoint.

Fast mode over Hermes SSH requires a Hermes gateway that advertises the ACP `service_tier` option and the Riptide SSH wrapper from this release. Apply the wrapper to an existing versioned pairing with the [SSH release updater](Host/update_ssh_release.py). Apply the [gateway chat speed patch](Host/compat/hermes-gateway-chat-speed.md) to remember each chat’s speed across gateway restarts.

### Send files privately to an SSH-paired host

In the chat composer, tap **+ → Send File to VPS**, choose a file up to 100 MiB, and confirm **Upload**. Riptide streams the file in chunks over the existing pinned SSH pairing and shows progress as the VPS acknowledges each chunk. The file and its path stay outside the transcript. Use **Copy VPS Path** to use the uploaded file from the paired account. The VPS stores completed files in temporary directories with owner-only permissions and removes incomplete uploads when the connection closes. Move the file to its intended location or remove the temporary copy after use.

This option is available for SSH-paired agents, including Hermes group chats through their paired host. For files over 1 MiB, update both the iPhone app and the VPS wrapper. Install the current `Host/ssh_acp.py` or apply the versioned [SSH release updater](Host/update_ssh_release.py) to the existing key. The transfer uses the existing restricted key and SSH port.

### Rename a paired agent from chat

In a paired ACP chat, say “Change your name to Harbor.” The `set_display_name` tool updates that agent’s label in Riptide, including its chat header and entry under **Agents**. Riptide saves the new label on the device when it receives the update. The same pairing keeps its chats, photo, and favorites.

With the updated iPhone app and host payload, create a directory owned by the agent’s host account with mode `0700`. Use a distinct absolute state file inside it for each agent, such as `/home/agent/.local/state/riptide-profiles/harbor.json`. Keep the same file across releases. The tool creates the file on its first successful call.

- **SSH** — Add `--agent-profile-state /absolute/path/to/agent.json` before the `--` separator in the paired key’s fixed `ssh_acp.py` command. For an existing versioned pairing, pass the same option to `Host/update_ssh_release.py`. Repeat for each agent you want to enable, with its own file.
- **Private WebSocket ACP** — Pass `--agent-profile-state /absolute/path/to/agent.json` to `Host/acp_bridge.py` before the fixed agent command.
- **Hermes using Codex App Server** — Apply [the Hermes gateway pairing adapter](Host/compat/hermes-gateway-pairing.md). Reconnect the chat after enabling the feature. The native Hermes MCP route uses the shared tool directly.

### Hermes group chats over SSH

Open **Groups → +** in Riptide, choose the Hermes connection that serves your bots, name the group, and select two to six bots from that gateway. The Groups tab lists rooms from every paired Hermes connection with group access, including rooms created in Hermes Desktop. Each room names the connection that owns it. Send to the group or use the **@** menu to address individual bots. Each reply shows its author, and **Reply in thread** continues a topic. Hermes stores the shared transcript and runs the turns while Riptide is closed.

Group chats require a running Hermes gateway that advertises a group driver. The picker uses its seatable profiles. If a profile-bound gateway leaves out a bot, configure it in the gateway’s `hosted_rooms.profiles` using the [Hermes Bot Mode guide](https://hermes-agent.nousresearch.com/docs/user-guide/bot-mode). Riptide can open existing gateway-owned rooms with peer members. Creating a room in Riptide uses bots from the selected gateway and supports text messages.

Stage the versioned Riptide host payload and run `Host/update_ssh_release.py` with the existing pairing fingerprint and release arguments plus `--enable-hermes-groups`. The updater reuses the paired Hermes profile and launcher from the screen route and verifies `groups.capabilities` before changing the key. For a pairing without a screen route, install `hermes_groups.py`, `hermes_screen.py`, and `hermes_mobile.py` alongside the updated `ssh_acp.py`, with the `websockets` Python dependency. Add `--hermes-groups /absolute/hermes/profile/home /absolute/path/to/hermes` before `--` in the fixed command. Grant this option to devices trusted to read and operate the group chats accessible to that profile. It uses the existing authenticated SSH pairing and Hermes’s local gateway ticket.

### One-tap Hermes pairing

An existing trusted Hermes-over-SSH pairing can offer a **Connect agent** button in chat for another Hermes profile on that host. Riptide creates a fresh key on-device only after the tap, sends just the public key over the current pinned SSH connection, checks the new connection, and saves it as a separate remote. It doesn't re-use the existing device key or let the invitation change the SSH host.

To enable it, deploy the versioned Host payload and give the **existing pairing's** fixed `ssh_acp.py` command an additional `--pairing-config /absolute/path/to/hermes-pairing.json` before its `--` separator. For a versioned installation, pass that same option to `Host/update_ssh_release.py` when switching the existing pairing to this release. Keep its existing workspace, SSH restrictions and agent command. Only grant this option to devices allowed to connect the profiles in the list. Keep the config owner-controlled and do not add the option to the new child pairings. Example:

```json
{
  "authorizedKeys": "/home/agent/.ssh/authorized_keys",
  "hermes": "/home/agent/.local/bin/hermes",
  "targets": {
    "bookkeeper": {
      "name": "Bookkeeper",
      "workspace": "/srv/bookkeeper",
      "mainSessionID": "an-existing-hermes-acp-chat-id"
    }
  }
}
```

Use the precise directory and ID returned by `hermes -p bookkeeper acp`'s `session/list`; creating a plain CLI chat does not make it visible to that catalog. The host verifies the configured chat before registering any key. The new key is restricted to `hermes -p <profile> acp` in the configured workspace. Existing keys are preserved. As with manual pairing, remove the generated restricted entry from `authorized_keys` to revoke a device's host access.

The SSH launcher adds the `riptide_pairing` MCP server to the paired chat when `--pairing-config` is set. Agents discover eligible profiles with `list_pairable_agents` and request device consent with `request_agent_pairing`. Both tools use the host manifest. The phone still validates and saves the new connection after the **Connect agent** tap. For several agents the runtime requests one approval per profile in the same chat.

Hermes' native runtime uses MCP form elicitation. For Hermes chats running through Codex App Server, apply [the gateway pairing adapter](Host/compat/hermes-gateway-pairing.md) to route the same form into the current Riptide chat. Install or update `Host/hermes-pairing/SKILL.md` under the source profile's `skills/riptide-hermes-pairing/` for pairing guidance and the native `clarify` fallback on older trusted connections.

For a gateway-managed Hermes chat, [the reconnect status patch](Host/compat/hermes-acp-turn-status.patch) lets Riptide recover the **Working** indicator from the same chat when SSH reconnects. Apply the patch from the Riptide release to the Hermes source at revision `8fc0374447313e276f6b9a2764bfc750190c966a`. Run `git apply --check /path/to/riptide/Host/compat/hermes-acp-turn-status.patch` before applying it with `git apply`. The next SSH connection starts a fresh ACP process and picks up the patch. Use `git apply -R` with the same patch to roll back. The patch can be applied alongside the gateway pairing and ACP steering compatibility patches.

Apply [the assistant progress patch](Host/compat/hermes-codex-assistant-progress.patch) after the reconnect status patch on that revision. Run `git apply --check`, then `git apply` with the patch path from the Riptide release, and restart the Hermes gateway after active turns finish. To roll back, use `git apply -R` and restart the gateway again.

Update trusted Hermes SSH pairings to the versioned wrapper that admits assistant progress before clients send the new capability. Use the same wrapper for future pairings.

ACP clients opt in with `clientCapabilities._meta["app.riptide.assistantProgress"] = true`. An `agent_message_chunk` with the same flag in `_meta` carries a complete progress update and uses the same `messageId` as any earlier deltas for that item. The app shows it until the turn ends. Connectors omit those updates from completed history. Codex App Server connections use the native message phase directly.

Apply [the screenshot transcript patch](Host/compat/hermes-codex-image-view-transcript.patch) after the assistant progress patch. It keeps Codex screenshot viewing activity out of new assistant replies and omits legacy screenshot records when ACP reopens a chat. Use the same apply, restart, and rollback procedure.

Apply [the context compaction patch](Host/compat/hermes-codex-context-compaction.patch) after the assistant progress patch to show live Codex compaction in gateway-managed Hermes chats. Use the same apply, restart, and rollback procedure. The patched gateway sends the lifecycle through ACP session metadata. Riptide can also display compactions from previously saved Hermes history.

### Hermes browser handoff over SSH

Configure [Hermes Bot Screen](https://hermes-agent.nousresearch.com/docs/user-guide/features/bot-screen) on the Linux gateway. Install its desktop packages, set `bot_desktop.auto_start: true` and `model.openai_runtime: codex_app_server` in the paired profile, and apply [the Hermes gateway patches](Host/compat/hermes-gateway-pairing.md). The SSH wrapper needs `websockets` and `--hermes-screen /absolute/hermes/profile/home /absolute/path/to/hermes` in the key’s forced command. Give this option only to devices trusted to control the profile’s desktop.

On Debian or Ubuntu, run this from the exact Riptide release as the owner of the Hermes profile. It installs Google Chrome Stable and Hermes’s native desktop driver. The desktop launcher opens Chrome with the existing profile and its sessions.

```sh
bash Host/deploy/install-hermes-stable-chrome.sh /absolute/path/to/hermes /absolute/hermes/profile/home
```

For a host where Chrome should be the default for all current and future Hermes pairings, run the rollout from the exact Riptide release using Hermes’s Python environment. It preserves the existing approved target list, migrates trusted Hermes keys, and prepares each configured Hermes profile. The manifest’s `chrome` policy prepares new profiles when you approve **Connect agent** in Riptide.

```sh
/absolute/hermes/venv/bin/python -B Host/deploy/enable-hermes-chrome.py \
  --manifest /absolute/hermes/home/riptide-pairing-manifest.json \
  --home /absolute/hermes/home --source /absolute/hermes/source \
  --python /absolute/hermes/venv/bin/python \
  --releases /absolute/riptide/releases --revision "$release_sha" --reload-gateway
```

Pass `--previous-releases` for any superseded versioned host roots and `--legacy-wrapper` for an approved non-versioned SSH wrapper. Add future profiles to the existing target list using their ACP main chat and workspace. The browser uses each profile's own desktop and persistent Chrome data by default.

For an existing versioned SSH deployment, stage the matching release and enable the Chrome connector for the paired device:

```sh
python3 -B Host/update_ssh_release.py --fingerprint 'SHA256:…' \
  --releases-dir /absolute/riptide/releases \
  --previous "$previous_sha" --revision "$release_sha" \
  --hermes-browser-mcp /absolute/hermes/venv/bin/python /absolute/path/to/hermes-source
```

For a paired profile without a Bot Screen route, pass `--hermes-screen /absolute/hermes/profile/home /absolute/path/to/hermes` in the same update. The profile home must match the Hermes profile used by that pairing.

Install `Host/hermes-browser-handoff/SKILL.md` under the profile’s `skills/riptide-browser-handoff/` and reopen the paired chat. Codex App Server uses Chrome through Hermes’s Linux computer-use driver. Its browser tools are scoped to the paired profile and follow the Bot Screen control lease. Chrome input uses Codex’s configured approval reviewer. The sign-in handoff uses the Riptide browser card.

In Riptide, choose **Chat actions → Open Hermes browser** or open the browser from the agent’s handoff card. Tap **Take over** to sign in directly in Chrome. Riptide fits the desktop to the phone and provides a keyboard and Password AutoFill. Tap **Hand back** to restore agent control and resume the chat. If the connection drops, reopen the browser and take over again. The adapter streams the existing desktop over the paired SSH connection using [noVNC 1.7.0](https://github.com/novnc/noVNC/tree/v1.7.0).

#### Share one existing Chrome desktop among trusted agents

By default every pairing uses its own Hermes desktop. To opt in on a VPS,
deploy this versioned Host release to the browser-enabled pairings. Then create
`riptide-shared-browser.json` in the root Hermes home (not in a named profile)
as an owner-controlled file, for example:

```json
{"owner":"browser-owner","members":["browser-owner","default","another-trusted-agent"]}
```

Use the slug of the existing Hermes profile whose desktop already has the Chrome
windows and sign-ins you want. The owner must also be a member. Include only
agents and their paired devices that you trust to see and interact with every
open Chrome window and signed-in browser session on that desktop. This does
not migrate, copy, or merge browser data or share any other agent capability.

If the pairing manifest is dedicated to agents you trust with the shared
desktop, pass `--share-with-pairable-agents` to the Chrome rollout above.
This adds the owner-controlled manifest as `pairing_manifest` in the existing
shared browser policy. A Chrome-enabled Riptide pairing for any current or
future target in that manifest then uses the shared desktop automatically.
Adding a target to that manifest carries the same desktop access as adding
it to `members`. Use explicit members for sharing with selected profiles.

On reconnect, listed Riptide pairings use that same desktop for browser
capture, reviewed input, and the phone's **Open Hermes browser** handoff. The
desktop's human control lease applies to all members, and input must follow
the latest capture across agents.
Before opening a sign-in page, agents call `computer_use(action="status")` to
read the current route and whether a shared desktop is configured without
opening Chrome. If the route changes, the old connector requires a reconnect
before browser use. Verify the requested Chrome profile on that desktop.
Check **Open Hermes browser** from two listed pairings and confirm you see the
same tab; take control from one and confirm agent capture is blocked until
handback. To revoke a profile's shared desktop access, remove it from all
configured membership sources and reconnect the affected chats. Remove
`pairing_manifest` to return to explicit membership for all pairings.

## Local Codex handoff proof

The debug build can also talk directly to a native Codex App Server on the same Mac. This proof path requires an explicit loopback WebSocket URL, a bearer token, and an absolute disposable workspace, supplied at launch as `RIPTIDE_CODEX_URL`, `RIPTIDE_CODEX_BEARER`, and `RIPTIDE_CODEX_WORKSPACE`. Use the `SIMCTL_CHILD_` prefix with `simctl launch`. Keep the listener on `127.0.0.1`, require capability-token authentication, and never put the token in the repo.

Start a read-only test turn in the official Codex terminal UI connected to that server with `codex --remote`. While it is running, choose **Codex on this Mac → Watch desktop turn** in Riptide. The app joins the one active chat in that exact workspace, displays live output, and sends **Steer** against the existing turn ID. It does not create turns or answer approvals. This is a local simulator proof, not ChatGPT Remote pairing or a general network connection feature.

The opt-in `CodexLiveUITests` flow expects a private directory containing the token file `bearer` and the disposable workspace `proof`. Set `TEST_RUNNER_RIPTIDE_CODEX_PROOF_DIR` to that directory and `TEST_RUNNER_RIPTIDE_CODEX_URL` to the loopback URL when running the test via `xcodebuild`. Start a terminal turn that emits progress for about two minutes and follows any later steering instruction. The test waits for fresh output, sends a marker, and verifies that the same turn returns it. Without the opt-in settings, the test is skipped.

## Composer dictation

Tap the microphone in a Codex or Hermes composer and speak. Tap **Stop Dictation** to add the transcript to your editable draft, or tap **Send** to transcribe and send it in one step. Recording stops after two minutes. The paired host forwards confirmed recordings to ChatGPT transcription using its existing Codex sign-in.

Enable the dictation relay on the host with Python 3.11+, curl, and the signed-in Codex account’s absolute, mode-0600 `auth.json` path. Sign in using ChatGPT. For Codex hosts, use the same sign-in as App Server. If Codex uses the OS credential store, select file storage with `cli_auth_credentials_store = "file"` and sign in there first. Run the relay as the OS user who owns that sign-in.

- **Hermes over SSH:** Install `Host/codex_dictation.py` alongside the updated `Host/ssh_acp.py`. Add `--codex-dictation-auth /absolute/path/to/.codex/auth.json` to the device’s forced command before `--`. New profiles paired through **Connect agent** inherit this setting from the trusted pairing that approved them. To enable dictation on a previously paired profile, pass the same option to `Host/update_ssh_release.py` with that pairing’s fingerprint. The dedicated channel uses the profile’s SSH key and pinned host, and returns text to the draft without opening an ACP session.
- **Hermes over WebSocket:** Install `Host/codex_dictation.py` alongside the updated `Host/acp_bridge.py`. Add `--codex-dictation-auth /absolute/path/to/.codex/auth.json` before `-- hermes acp` in the bridge command. Route `/riptide-dictation` to the same loopback bridge as `/acp`, on the same private TLS origin, with the Authorization header.
- **Codex over WebSocket:** Run the same Python bridge as a standalone dictation relay with `--port 8767 --token-file /absolute/path/to/capability-token --codex-dictation-auth /absolute/path/to/.codex/auth.json`. Use the same bearer token Riptide uses for App Server. On the existing private TLS origin, route only `/riptide-dictation` to the relay’s loopback port and forward the Authorization header. The App Server route continues to handle chats.

The host rereads the Codex sign-in for each request. Renew an expired sign-in through Codex. ChatGPT receives the recording when you confirm it and applies its service retention. The paired host relays the recording in memory and returns only the transcription to the phone.

## Codex subscription voice

Riptide uses the host's existing ChatGPT sign-in and refuses API-key accounts. It negotiates the experimental Codex App Server WebRTC route; media goes directly between the phone and the voice service. Use **Call Codex directly** from a Codex tab's menu for a separate, ephemeral, read-only call. Tap the phone icon inside a saved chat to speak with that exact thread and its context without replacing the chat connection or changing host permissions. Calls are outgoing and use iOS system call controls. The call stays connected when you lock your iPhone or switch apps.

Tap the down chevron to minimize a call and keep using Riptide. Tap the call bar to return to the controls. In a saved chat, **Call ended** shows the duration and expands to show the captured transcript, which stays on this iPhone. Open **Voice settings** to choose the agent’s voice for its next call.

Use an App Server build with realtime v3 WebRTC support and a ChatGPT account with Codex voice access. The opt-in simulator test above also checks that WebRTC connects and closes with microphone access disabled. Test actual capture and playback on an iPhone before relying on the call.

## Hermes and OpenClaw voice

Pair the agent's ACP chat first. The phone button calls in the open chat. Long-press it for **New voice chat** or **Voice settings**. Hermes profiles paired over SSH use that pairing to start a subscription call unless a manual route has already been saved. WebRTC carries live audio. Manual routes need a trusted TLS endpoint with the same hostname as the chat endpoint and may use a different port.

- **Hermes Talk (ChatGPT subscription)** requires a compatible Hermes host and [Hermes Talk plugin](https://github.com/TheSmokeDev/hermes-talk/blob/55ae7b29082faf5aaebac7cb7d692c3c2f8ade4f/docs/GPT-LIVE.md) with Dashboard task context and canonical task support. Set `TALK_VOICE_MODE=live` and `TALK_LIVE_AUTH=subscription` for the service lifetime. Sign into Codex as the account running the plugin. Use the same local Hermes profile for voice and ACP. The selected ACP session must appear in Talk’s authorized task catalog.
  - For **all Hermes profiles paired over SSH** on a compatible gateway, run `Host/deploy/stage-hermes-voice.py --all-pairings` with the installed `--hermes` launcher, root `--hermes-home`, absolute `--releases-dir` and private `--state-dir`, the full Riptide `--revision`, installed `--hermes-source` and `--hermes-python`, and existing `--codex-auth`. The script stages the pinned Talk transport, checks the voice route for every matching restricted SSH key, then switches them together. Profiles added later through **Connect agent** inherit the host’s Talk setup and use the profile and workspace bound to their own key. No Dashboard listener, second phone pairing, or gateway restart is required.
  - To enable a single existing SSH pairing, use `--fingerprint` instead of `--all-pairings`. Pass the printed private configuration path as `--hermes-talk-config` to `Host/update_ssh_release.py` for that fingerprint and revision.
  - To use an existing local Talk Dashboard over SSH, give the updater a mode-0600 configuration with `port` for the loopback Dashboard, `profile` for the key’s Hermes profile, `dashboardToken` for its session token, and `talkToken` if configured.
  - For manual setup, choose **Talk · ChatGPT subscription** and enter the private Dashboard HTTPS origin and session token, the Hermes profile if applicable, and the Talk token if required.
- **Hermes built-in GPT-Live (API billing):** This separate, explicitly selected route uses the [Hermes built-in voice API](https://hermes-agent.nousresearch.com/docs/user-guide/features/voice-mode). The host provisions its voice provider. Riptide seeds the call from the open chat and routes delegated requests back into its ACP session with existing approvals. No provider key goes on the phone.
- **OpenClaw:** Use a Gateway and voice provider that support [gateway-controlled WebRTC Talk](https://docs.openclaw.ai/gateway/protocol/transport#gateway-controlled-webrtc-talk). Enter the private Gateway `wss://` endpoint and its pairing credential. If prompted, approve the exact device request on the Gateway and retry; Riptide saves the device's scoped `operator.talk` token instead of the shared credential. The Gateway owns voice turns and their approvals. The ACP host must report the selected chat's Gateway session key. A new voice chat starts only if the host confirms a distinct key.

Riptide checks the OAuth subscription lane before opening WebRTC. The SSH adapter uses the canonical Hermes gateway to save delegated voice requests and replies in the open chat. The updated SSH adapter also supplies the call transcript and subscription voice choices to Riptide. Manually paired Hermes routes and OpenClaw use the voice configured on their host. Hermes retains its ordinary tool and clarification approvals, which the paired chat displays. Ending a call releases its audio session and lets accepted work finish. Riptide reloads the selected chat through ACP to pick up saved history. After deployment, verify audio capture, playback, and the system call controls on a physical iPhone.

Hermes and OpenClaw calls are outgoing. CallKit handles their system call controls, interruptions, and audio while Riptide is in the background.
