import RiptideCore
import SwiftUI

struct CodexMainChatScreen: View {
    let endpoint: CodexLocalEndpoint
    let workspaceID: String
    let showSideChats: (() -> Void)?
    @Environment(WorkspaceState.self) private var workspace
    @State private var initialChat: CodexChatSummary?
    @State private var resolved = false
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            if resolved {
                CodexSavedChatScreen(endpoint: endpoint, initialChat: initialChat, workspaceID: workspaceID,
                                    isMainChat: true, showSideChats: showSideChats)
            } else if let failure {
                ContentUnavailableView {
                    Label("Chat unavailable", systemImage: "bubble.left")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Retry") { attempt += 1 }.buttonStyle(.borderedProminent)
                }
            } else {
                ChatHistorySkeleton()
            }
        }
        .navigationTitle("Main Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !resolved, let showSideChats {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        SideChatsButton(action: showSideChats)
                    } label: {
                        Label("Chat actions", systemImage: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("codex-chat-actions")
                }
            }
        }
        .task(id: attempt) { await resolve() }
    }

    private func resolve() async {
        guard !resolved else { return }
        if let id = workspace.mainChatID(for: workspaceID) {
            initialChat = CodexChatSummary(id: id, title: workspace.displayName(for: .init(workspace: workspaceID, chat: id)))
            resolved = true
            return
        }
        failure = nil
        let client = endpoint.makeClient()
        do {
            let chats = try await client.listSavedChats(maximumPages: 1)
            try Task.checkCancellation()
            workspace.rememberCodexCatalog(chats, workspaceID: workspaceID)
            if let first = chats.first {
                workspace.useCodexMainChat(first.id, workspaceID: workspaceID)
            }
            if let id = workspace.mainChatID(for: workspaceID) {
                initialChat = chats.first { $0.id == id } ??
                    CodexChatSummary(id: id, title: workspace.displayName(for: .init(workspace: workspaceID, chat: id)))
            }
            resolved = true
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
        await client.close()
    }
}

struct CodexSavedChatScreen: View {
    let endpoint: CodexLocalEndpoint
    let initialChat: CodexChatSummary?
    let workspaceID: String
    var isMainChat = false
    var showSideChats: (() -> Void)? = nil
    @State private var session: CodexWorkspaceSession?
    @State private var draft = ""
    @State private var draftAttachments: [ChatAttachment] = []
    @State private var showVoiceSettings = false
    @State private var showModelPicker = false
    @State private var composerHeight: CGFloat = 0
    @State private var viewport = TranscriptViewport()
    @State private var showsCompletedToolCalls = false
    @State private var composerFocused = false
    @Environment(WorkspaceState.self) private var workspace

    private var chat: CodexChatSummary? { session?.chat }
    private var title: String { isMainChat ? "Main Chat" : chat?.title ?? initialChat?.title ?? "New chat" }
    private var turns: [CodexTranscriptTurn] { session?.turns ?? [] }
    private var activeTurnID: String? { session?.activeTurnID }
    private var hasCompletedToolCalls: Bool {
        turns.contains { $0.id != activeTurnID && !$0.progress.items.isEmpty }
    }
    private var approvals: [CodexChatApproval] { session?.approvals ?? [] }
    private var responding: Set<UUID> { session?.responding ?? [] }
    private var ready: Bool { session?.ready == true }
    private var working: Bool { session?.working == true }
    private var stopping: Bool { session?.stopping == true }
    private var sending: Bool { session?.sending == true }
    private var canSubmit: Bool { ready && !sending && !stopping && session?.configuring != true }
    private var composerSettings: ChatComposerSettings {
        .init(options: session?.configOptions ?? [], configuring: session?.configuring == true,
              working: working || sending, error: session?.configError) { [session] id, value in
            await session?.setConfigOption(id, value: value) ?? false
        }
    }
    private var progress: CodexTurnProgress { session?.progress ?? .init() }

    private var chatKey: WorkspaceChatID? {
        (chat ?? initialChat).map { .init(workspace: workspaceID, chat: $0.id) }
    }

    private var editor: Binding<String> {
        guard let chatKey else { return $draft }
        return Binding(get: { workspace.drafts[chatKey] }, set: { workspace.drafts[chatKey] = $0 })
    }

    private var attachments: Binding<[ChatAttachment]> {
        guard let chatKey else { return $draftAttachments }
        return Binding(
            get: { workspace.drafts[attachments: chatKey] },
            set: { workspace.drafts[attachments: chatKey] = $0 }
        )
    }

    var body: some View {
        transcript
        .accessibilityHidden(showModelPicker && composerSettings.hasChoices)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if ready, let session {
                VStack(alignment: .leading, spacing: 0) {
                    ComposerQueue(messages: session.queuedMessages, sendingID: session.sendingQueuedID,
                                  paused: session.queuePaused, canResume: !stopping,
                                  remove: session.removeQueuedMessage, resume: session.resumeQueue)
                    composer
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
            }
        }
        .modifier(ChatModelPicker(settings: composerSettings, composerHeight: composerHeight,
                                  chatID: chatKey?.chat, isExpanded: $showModelPicker))
        .background(ChatTheme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                WorkspaceChatHeading(title: title, workspaceName: workspace.agent(workspaceID)?.name ?? "Codex")
                    .accessibilityIdentifier("chat-heading")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    if let showSideChats {
                        SideChatsButton(action: showSideChats)
                    }
                    if let chatKey {
                        if hasCompletedToolCalls {
                            ToolCallsMenuButton(showsCompletedCalls: $showsCompletedToolCalls)
                        }
                        FollowUpButton(chat: chatKey, title: title)
                    }
                    Button("Call Codex directly", systemImage: "phone") {
                        workspace.calls.present(.codex(CodexVoiceCallModel(endpoint: endpoint, workspace: workspace,
                                                                          workspaceID: workspaceID)))
                    }
                    .disabled(!workspace.calls.canOpen())
                    .accessibilityIdentifier("call-codex-direct")
                    Button("Voice settings", systemImage: "waveform") { showVoiceSettings = true }
                        .accessibilityIdentifier("codex-voice-settings")
                    WorkspaceSearchButton()
                    Button("Open Inbox", systemImage: "tray") { workspace.showSidebar(.inbox) }
                } label: { Label("Chat actions", systemImage: "ellipsis.circle") }
                .accessibilityIdentifier("codex-chat-actions")
                Button("Call in this chat", systemImage: "phone") {
                    if workspace.calls.active?.chat == chatKey, workspace.calls.active != nil { workspace.calls.resume() }
                    else if let session {
                        workspace.calls.present(.codex(CodexVoiceCallModel(endpoint: endpoint, workspace: workspace,
                                                                         workspaceID: workspaceID, session: session)))
                    }
                }
                    .labelStyle(.iconOnly)
                    .disabled(!ready || chat == nil || !workspace.calls.canOpen(chat: chatKey))
                    .accessibilityIdentifier("call-codex-in-chat")
            }
        }
        .sheet(isPresented: $showVoiceSettings) {
            AgentVoiceSettings(workspaceID: workspaceID, availableVoices: { try await endpoint.subscriptionVoices() })
        }
        .task {
            let active = session ?? workspace.codexSession(endpoint: endpoint, initialChat: initialChat, workspaceID: workspaceID,
                                                           isMainChat: isMainChat)
            session = active
            workspace.retain(active)
            active.start()
            visitIfReady()
        }
        .onChange(of: ready) { visitIfReady() }
        .onChange(of: chat?.id) { visitIfReady() }
        .onChange(of: activeTurnID) { showsCompletedToolCalls = false }
        .onDisappear {
            if let chatKey { workspace.leave(chatKey) }
        }
    }

    private func visitIfReady() {
        guard ready, let chatKey else { return }
        workspace.visit(chatKey, title: title)
    }

    private var transcript: some View {
        let latestUserMessage = turns.latestUserMessageLocation(activeTurnID: activeTurnID)
        let activeTurn = turns.last { $0.id == activeTurnID }
        let firstActiveOutput = activeTurn?.entries.first { entry in
            if case .message(let message) = entry { return message.role != .user }
            return true
        }
        let startedAt = session?.activeTurnStartedAt
        let calls = workspace.calls.records(in: chatKey)
        let turnIDs = Set(turns.map(\.id))
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if session?.hasOlderTurns == true {
                    Text("Showing the latest 30 turns.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(calls.filter {
                    if case .codexMessage(let id, _) = $0.anchor { return id.map { !turnIDs.contains($0) } ?? true }
                    return false
                }) { ChatCallReceipt(record: $0) }
                ForEach(turns) { turn in
                    let visibleEntries = turn.visibleEntries(isActive: turn.id == activeTurnID)
                    let visibleIDs = Set(visibleEntries.map(\.id))
                    let turnCalls = calls.filter {
                        if case .codexMessage(let id, _) = $0.anchor { return id == turn.id }
                        return false
                    }
                    ForEach(visibleEntries) { entry in
                        if turn.id == activeTurnID, entry.id == firstActiveOutput?.id, let startedAt {
                            WorkingTurnHeader(startedAt: startedAt)
                        }
                        switch entry {
                        case .message(let message):
                            let showsReceipt = turn.id == latestUserMessage?.turnID &&
                                message.id == latestUserMessage?.messageID
                            transcriptMessage(message, showsReceipt: showsReceipt)
                            ForEach(turnCalls.filter { $0.anchor == .codexMessage(turn: turn.id, after: message.id) }) {
                                ChatCallReceipt(record: $0)
                            }
                        case .contextCompaction(let compaction):
                            ContextCompactionLine(compaction: compaction)
                        }
                    }
                    if showsCompletedToolCalls && turn.id != activeTurnID && !turn.progress.items.isEmpty {
                        CodexActivityList(items: turn.progress.items)
                            .padding(12)
                            .contentPanel()
                    }
                    ForEach(turnCalls.filter {
                        if case .codexMessage(_, let id) = $0.anchor { return id.map { !visibleIDs.contains(.message($0)) } ?? true }
                        return false
                    }) { ChatCallReceipt(record: $0) }
                }
                if workspace.calls.saveFailure == chatKey, chatKey != nil {
                    Text("This call couldn’t be saved on this device.").font(.footnote).foregroundStyle(.secondary)
                }
                if firstActiveOutput == nil, let startedAt {
                    WorkingTurnHeader(startedAt: startedAt)
                }
                if let diff = session?.diff {
                    DisclosureGroup("Changes") { DiffPreview(source: diff, title: "Turn diff") }
                }
                ForEach(approvals) { approval in
                    if let questions = approval.questions {
                        CodexInputCard(questions: questions, responding: responding.contains(approval.id)) { values in
                            session?.answerInput(approval, values: values)
                        }
                    } else {
                        approvalCard(approval)
                    }
                }
                if let issue = session?.issue {
                    Text(issue).font(.footnote).foregroundStyle(.secondary)
                    if !ready { Button("Reconnect") { session?.start() } }
                } else if !ready {
                    ProgressView("Opening chat…")
                } else if calls.isEmpty && turns.allSatisfy({ $0.visibleEntries(isActive: false).isEmpty }) && !working {
                    Text("Start a conversation").foregroundStyle(.secondary)
                }
                if let sendIssue = session?.sendIssue {
                    Text(sendIssue).font(.footnote).foregroundStyle(.secondary)
                }
                if !progress.plan.isEmpty { TurnPlanCard(steps: progress.plan) }
                if let activeTurnID, activeTurn?.isCompactingContext != true {
                    let current = progress.items.last {
                        $0.state == .running && $0.kind != .summary && $0.kind != .planning
                    }
                    LiveTurnActivity(currentTool: current?.title, hasActivity: !progress.items.isEmpty) {
                        CodexActivityList(items: progress.items)
                    }
                    .id(activeTurnID)
                }
            }
            .transcriptColumn()
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("codex-saved-transcript")
        .transcriptViewport($viewport, chat: ready ? chatKey : nil, composerFocused: composerFocused)
    }

    @ViewBuilder
    private func transcriptMessage(_ message: CodexChatMessage, showsReceipt: Bool) -> some View {
        if message.role == .user {
            TranscriptUserMessage(text: message.text, photos: message.photos,
                                  receipt: showsReceipt ? message.receipt : nil, photoClient: session?.client)
        } else if !message.text.isEmpty {
            ChatMarkdown(source: message.text, streaming: message.streaming)
        }
    }

    private var composer: some View {
        ChatComposer(
            prompt: working ? "Follow up" : "Message Codex",
            chatID: chatKey?.chat, fieldID: "codex-composer",
            sendID: working ? "codex-steer-send" : "send-message", stopID: "stop-codex-turn", stopTitle: "Stop turn", draft: editor, attachments: attachments,
            modelPickerVisible: $showModelPicker, editorFocus: $composerFocused,
            settings: composerSettings, context: session?.context, canDictate: canSubmit, canSubmit: canSubmit,
            transcribe: DictationFixture.transcribe ?? endpoint.dictation.transcribe,
            submission: working ? .steer : .send, stopping: stopping,
            stop: working ? { Task { await session?.interrupt() } } : nil,
            enqueue: working ? { submitDraft(queue: true) } : nil,
            submit: { submitDraft(queue: false) }
        )
    }

    private func approvalCard(_ approval: CodexChatApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(approval.isInput ? "Input requested" : "Approval requested")
                .font(.subheadline.weight(.semibold)).foregroundStyle(ChatTheme.attention)
            if let reason = approval.reason { Text(reason).font(.footnote) }
            if let command = approval.command { CodePreview(source: command, language: "shell") }
            if let cwd = approval.cwd { Text(cwd).font(.caption).foregroundStyle(.secondary) }
            if !approval.canAllow {
                Text(approval.isInput ? "Answer this request in Codex on the host." : "Review this action in Codex on the host.")
                    .font(.footnote)
            }
            HStack {
                if approval.canAllow {
                    Button("Allow once") { session?.answer(approval, allow: true) }.buttonStyle(.bordered)
                }
                if approval.canDecline {
                    Button("Decline") { session?.answer(approval, allow: false) }.buttonStyle(.bordered)
                }
            }
            .disabled(responding.contains(approval.id))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .contentPanel()
    }

    private func submitDraft(queue: Bool) {
        guard let session, canSubmit else { return }
        let message = ComposerDraft(text: editor, files: attachments)
        guard message.hasContent else { return }
        composerFocused = false
        viewport.jumpToLatest()
        if queue {
            session.enqueue(message.text, attachments: message.attachments)
            message.clear()
        } else {
            Task {
                if await session.send(message.text, attachments: message.attachments) != nil { message.clear() }
            }
        }
    }

}

private struct CodexInputCard: View {
    let questions: [CodexInputQuestion]
    let responding: Bool
    let submit: ([String: String]) -> Void
    @State private var choices: [String: String] = [:]
    @State private var custom: [String: String] = [:]

    private var answers: [String: String] {
        Dictionary(uniqueKeysWithValues: questions.compactMap {
            let text = choices[$0.id] ?? custom[$0.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let text, !text.isEmpty else { return nil }
            return ($0.id, text)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Codex needs your input", systemImage: "text.bubble")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ChatTheme.warning)
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    if !question.header.isEmpty { Text(question.header).font(.caption.weight(.semibold)).foregroundStyle(ChatTheme.muted) }
                    Text(question.prompt).font(.subheadline)
                    ForEach(question.options) { option in
                        Button {
                            choices[question.id] = option.label
                            custom[question.id] = nil
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(option.label).font(.subheadline.weight(.semibold))
                                    if !option.detail.isEmpty { Text(option.detail).font(.caption).foregroundStyle(ChatTheme.muted) }
                                }
                                Spacer()
                                Image(systemName: choices[question.id] == option.label ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(ChatTheme.accent)
                                    .accessibilityHidden(true)
                            }
                            .padding(10)
                            .frame(minHeight: 44)
                            .background(ChatTheme.raised, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(choices[question.id] == option.label ? .isSelected : [])
                    }
                    if question.acceptsFreeText {
                        TextField(question.options.isEmpty ? "Your answer" : "Other answer", text: Binding(
                            get: { custom[question.id, default: ""] },
                            set: { custom[question.id] = String($0.prefix(1_000)); choices[question.id] = nil }
                        ), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                    }
                }
            }
            Button(responding ? "Sending…" : "Submit answers") { submit(answers) }
                .buttonStyle(.borderedProminent)
                .disabled(answers.count != questions.count || responding)
        }
        .disabled(responding)
        .padding(14)
        .contentPanel()
    }
}
