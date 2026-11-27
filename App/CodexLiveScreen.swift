import RiptideCore
import SwiftUI

struct CodexLiveScreen: View {
    let endpoint: CodexLocalEndpoint
    @Environment(WorkspaceState.self) private var workspace
    @State private var session: CodexWorkspaceSession?
    @State private var turn: CodexLiveTurn?
    @State private var watchedTurnStartedAt: Date?
    @State private var status = "Joining the running turn…"
    @State private var active = false
    @State private var failure: String?
    @State private var attempt = 0
    @State private var draft = ""
    @State private var attachments: [ChatAttachment] = []
    @State private var receipt: String?
    @State private var output = ""
    @State private var outputEvents = 0
    @State private var replies = CodexTranscriptTurn(id: "")
    @State private var patch: String?
    @State private var context: ContextUsage?
    @State private var viewport = TranscriptViewport()
    @State private var editorFocused = false

    private var workingSince: Date? {
        if active { return watchedTurnStartedAt }
        guard session?.activeTurnID != turn?.turnID else { return nil }
        return session?.activeTurnStartedAt
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(status).font(.headline)
                            .foregroundStyle(active ? ChatTheme.accent : Color.primary)
                            .accessibilityIdentifier("codex-turn-status")
                        if let turn {
                            Text("\(turn.model ?? "Codex") · Turn \(turn.turnID.suffix(8))")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("codex-turn-id")
                        }
                    }
                    if let prompt = turn?.prompt {
                        Text(prompt)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let workingSince {
                        WorkingTurnHeader(startedAt: workingSince)
                    }
                    if outputEvents > 0 {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Live output · \(outputEvents) updates")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("codex-live-updates")
                            Text(output.trimmingCharacters(in: .newlines))
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("codex-live-output")
                        }
                        .padding(12)
                        .background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    ForEach(replies.visibleEntries(isActive: active)) { entry in
                        switch entry {
                        case .message(let reply):
                            ChatMarkdown(source: reply.text, streaming: active && reply.streaming)
                                .accessibilityIdentifier("codex-assistant-reply")
                        case .contextCompaction(let compaction):
                            ContextCompactionLine(compaction: compaction)
                        }
                    }
                    if let turn, let session {
                        let followUps = session.turns.drop(while: { $0.id != turn.turnID })
                        let latestUserMessage = followUps.latestUserMessageLocation(activeTurnID: session.activeTurnID)
                        ForEach(followUps) { followUp in
                            let firstUserID = followUp.messages.first { $0.role == .user }?.id
                            ForEach(followUp.visibleEntries(isActive: followUp.id == session.activeTurnID)) { entry in
                                switch entry {
                                case .message(let message):
                                    if message.role == .user {
                                        if followUp.id != turn.turnID || message.id != firstUserID {
                                            let showsReceipt = followUp.id == latestUserMessage?.turnID &&
                                                message.id == latestUserMessage?.messageID
                                            TranscriptUserMessage(text: message.text, photos: message.photos,
                                                                  receipt: showsReceipt ? message.receipt : nil, photoClient: session.client)
                                        }
                                    } else if followUp.id != turn.turnID {
                                        ChatMarkdown(source: message.text, streaming: message.streaming)
                                    }
                                case .contextCompaction(let compaction):
                                    if followUp.id != turn.turnID {
                                        ContextCompactionLine(compaction: compaction)
                                    }
                                }
                            }
                        }
                    }
                    if let patch, !patch.isEmpty {
                        DisclosureGroup("Changes") {
                            DiffPreview(source: patch, title: "Turn diff")
                                .padding(.top, 8)
                        }
                        .font(.subheadline)
                    }
                    if let receipt {
                        Text(receipt).font(.footnote).foregroundStyle(ChatTheme.accent)
                            .accessibilityIdentifier("codex-steer-receipt")
                    }
                    if let failure {
                        Text(failure).font(.footnote).foregroundStyle(.secondary)
                        if !active {
                            Button("Join running turn") { attempt += 1 }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("codex-reconnect")
                        }
                    }
                    if let issue = session?.sendIssue ?? session?.issue {
                        Text(issue).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .transcriptColumn()
            }
            .scrollDismissesKeyboard(.interactively)
            .transcriptViewport($viewport, composerFocused: editorFocused)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let session, session.ready {
                    VStack(alignment: .leading, spacing: 0) {
                        ComposerQueue(messages: session.queuedMessages, sendingID: session.sendingQueuedID,
                                      paused: session.queuePaused, canResume: !session.stopping,
                                      remove: session.removeQueuedMessage, resume: session.resumeQueue)
                        composer(session)
                    }
                }
            }
        }
        .background(ChatTheme.background.ignoresSafeArea())
        .navigationTitle("Codex on this Mac")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink {
                    CodexChatsScreen(endpoint: endpoint, name: "Chats")
                } label: {
                    Label("Saved chats", systemImage: "bubble.left.and.bubble.right").labelStyle(.iconOnly)
                }
                .accessibilityIdentifier("saved-codex-chats")
                Button("Call Codex", systemImage: "phone") {
                    workspace.calls.present(.codex(CodexVoiceCallModel(endpoint: endpoint, workspace: workspace,
                                                                     workspaceID: WorkspaceState.localID)))
                }
                    .disabled(!workspace.calls.canOpen())
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("call-codex")
            }
        }
        .task(id: attempt) { await watch() }
    }

    private func composer(_ session: CodexWorkspaceSession) -> some View {
        let canSubmit = !session.sending && !session.stopping && !session.configuring
        return ChatComposer(
            prompt: session.working ? "Follow up" : "Message Codex",
            chatID: turn?.threadID, fieldID: "codex-steer-input", sendID: "codex-steer-send", draft: $draft, attachments: $attachments,
            modelPickerVisible: .constant(false), editorFocus: $editorFocused, context: session.context ?? context,
            canDictate: canSubmit, canSubmit: canSubmit,
            transcribe: DictationFixture.transcribe ?? endpoint.dictation.transcribe,
            submission: session.working ? .steer : .send,
            enqueue: session.working ? { submitDraft(queue: true) } : nil,
            submit: { submitDraft(queue: false) }
        )
    }

    private func watch() async {
        viewport.jumpToLatest()
        let peer = endpoint.makeClient()
        session = nil
        turn = nil
        watchedTurnStartedAt = nil
        active = false
        status = "Joining the running turn…"
        failure = nil
        receipt = nil
        output = ""
        outputEvents = 0
        replies = CodexTranscriptTurn(id: "")
        patch = nil
        context = nil
        do {
            let joined = try await peer.attach()
            turn = joined
            let now = Date.now
            watchedTurnStartedAt = min(joined.startedAt ?? now, now)
            for compaction in joined.compactions { replies.upsert(compaction) }
            let saved = workspace.codexSession(endpoint: endpoint,
                                               initialChat: .init(id: joined.threadID, title: "Codex on this Mac"),
                                               workspaceID: WorkspaceState.localID)
            session = saved
            saved.start()
            active = true
            status = "Watching a turn already in progress"
            for try await event in peer.events {
                switch event {
                case .output(_, let text):
                    output = String((output + text).suffix(3_000))
                    outputEvents += 1
                case .assistantDelta(_, let itemID, let text):
                    replies.appendReply(text, id: itemID)
                case .assistantCompleted(_, let message):
                    replies.upsert(message)
                case .contextCompaction(_, let compaction):
                    replies.upsert(compaction)
                case .diff(_, let update):
                    patch = update
                case .context(_, let usage):
                    context = usage
                case .completed(_, let outcome):
                    context = nil
                    status = outcome == "completed" ? "Turn completed" : "Turn \(outcome)"
                    active = false
                    await peer.close()
                    return
                }
            }
        } catch {
            if !Task.isCancelled {
                status = (error as? CodexLiveError) == .noActiveTurn
                    ? "No active chat turn" : (turn == nil ? "Couldn’t join a turn" : "Connection closed")
                failure = error.localizedDescription
            }
        }
        active = false
        await peer.close()
    }

    private func submitDraft(queue: Bool) {
        let message = ComposerDraft(text: $draft, files: $attachments)
        guard let session, session.ready, !session.sending, !session.stopping, !session.configuring, message.hasContent else { return }
        editorFocused = false
        if queue {
            session.enqueue(message.text, attachments: message.attachments)
            message.clear()
        } else {
            Task {
                guard let delivery = await session.send(message.text, attachments: message.attachments) else { return }
                if case .steered(let id) = delivery { receipt = "Steering accepted · Turn \(id.suffix(8))" }
                message.clear()
            }
        }
    }
}
