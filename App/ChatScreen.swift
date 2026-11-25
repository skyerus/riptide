import RiptideCore
import SwiftUI

struct ChatScreen: View {
    let model: AgentChatModel
    var voiceRemote: RemoteProfile? = nil
    var remoteStore: RemoteStore? = nil
    var initialChatID: String? = nil
    @State private var showChats = false
    @State private var showModelPicker = false
    @State private var showAdvancedModelPicker = false
    @State private var composerHeight: CGFloat = 0
    @State private var landing = true
    @State private var couldNotOpen = false
    @State private var viewport = TranscriptViewport()
    @State private var showsCompletedToolCalls = false
    @State private var pairingVoice = false
    @State private var activeCall: ChatCall?
    @State private var voiceError: String?
    @State private var browserHandoff: BrowserHandoff?
    @State private var safariApproval = SafariChatApproval()
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(WorkspaceState.self) private var workspace

    private var chatKey: WorkspaceChatID { .init(workspace: model.target.id, chat: model.selectedID) }
    private var dictationTranscriber: DictationTranscriber? {
        if let voiceRemote, let bearer = remoteStore?.bearer(for: voiceRemote),
           let dictation = voiceRemote.makeHermesDictation(credential: bearer) {
            return dictation.transcribe
        }
        return model.target.id == "hermes" ? DictationFixture.transcribe : nil
    }

    private var pickerIsOpen: Bool {
        showModelPicker && !resolvingInitialChat && model.selected.hasConfigChoices
    }

    private var resolvingInitialChat: Bool {
        landing && model.selectedID != (initialChatID ?? model.target.mainSessionID)
    }

    private var awaitingHistory: Bool {
        resolvingInitialChat || (!model.selected.loaded && model.selected.error == nil &&
                                 model.selected.transcript.entries.isEmpty && model.selected.permissions.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            if couldNotOpen {
                ContentUnavailableView {
                    Label("Chat unavailable", systemImage: "bubble.left")
                } description: {
                    Text("This connector didn’t list the saved chat.")
                } actions: {
                    Button("Open Main Chat") {
                        Task {
                            model.selectMain()
                            couldNotOpen = false
                            await model.showMain()
                            visit()
                        }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                chat
            }
        }
        .background(ChatTheme.background.ignoresSafeArea())
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    showChats = true
                } label: {
                    WorkspaceChatHeading(title: model.title, workspaceName: model.target.name)
                }
                .buttonStyle(.plain)
                .workspaceFlickNavigation(model.target.id)
                .accessibilityLabel(model.title)
                .accessibilityValue(model.target.name)
                .accessibilityHint("Switch or start a chat")
                .accessibilityIdentifier("chats-button")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    if model.selected.transcript.hasCompletedToolCalls {
                        ToolCallsMenuButton(showsCompletedCalls: $showsCompletedToolCalls)
                    }
                    FollowUpButton(chat: chatKey, title: model.title)
                    if let remote = voiceRemote, remote.canOpenHermesScreen,
                       let credential = remoteStore?.bearer(for: remote) {
                        Button("Open Hermes browser", systemImage: "macwindow") {
                            openBrowser(remote, credential: credential)
                        }
                        .accessibilityIdentifier("open-hermes-browser")
                    }
                    Button("Open Inbox", systemImage: "tray") { workspace.showSidebar(.inbox) }
                } label: {
                    Label("Chat actions", systemImage: "ellipsis.circle")
                }
                .disabled(landing || couldNotOpen || !model.selected.loaded)
                .accessibilityIdentifier("chat-actions")
                if voiceRemote != nil {
                    Button("Call in this chat", systemImage: "phone") { startCall() }
                        .labelStyle(.iconOnly)
                        .disabled(!model.selected.loaded || activeCall != nil)
                        .accessibilityIdentifier("native-call-in-chat")
                        .contextMenu {
                            Button("New voice chat", systemImage: "plus.bubble") {
                                guard let voiceRemote, let remoteStore else { return }
                                guard remoteStore.voice(for: voiceRemote) != nil else { pairingVoice = true; return }
                                Task {
                                    if await model.createChat(openClaw: voiceRemote.kind == .openClaw) {
                                        startCall()
                                    } else if let error = model.listError {
                                        voiceError = error
                                    }
                                }
                            }
                            .disabled(!model.selected.loaded || model.creatingChat || model.selected.working)
                            Button("Voice settings", systemImage: "gearshape") { pairingVoice = true }
                        }
                }
            }
        }
        .sheet(isPresented: $showChats) {
            ChatPicker(model: model, openClaw: voiceRemote?.kind == .openClaw)
        }
        .sheet(isPresented: $showAdvancedModelPicker) {
            AdvancedModelPicker(model: model, sessionID: model.selectedID)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
        }
        .task(id: chatKey) {
            safariApproval.restore(agentID: voiceRemote?.id, chatID: chatKey.chat)
        }
        .onChange(of: model.selectedID) {
            safariApproval.cancelTurn()
            showModelPicker = false
            showAdvancedModelPicker = false
        }
        .sheet(isPresented: $pairingVoice) {
            if let voiceRemote, let remoteStore { PairNativeVoiceScreen(remote: voiceRemote, store: remoteStore) }
        }
        .fullScreenCover(item: $browserHandoff) { handoff in
            HermesScreen(remote: handoff.remote, credential: handoff.credential, canContinue: {
                guard model.selectedID == handoff.chatID, model.selected.loaded, !model.selected.stopping else { return false }
                if let request = handoff.request { return model.selected.permissions.contains(request) }
                return !model.selected.working
            }, onContinue: {
                guard model.selectedID == handoff.chatID else { return }
                if let request = handoff.request, let option = browserCompletion(in: request) {
                    Task { await model.answer(request, optionID: option.id) }
                } else {
                    model.submit("I’ve handed back control of your browser. Continue the task from the open browser session.")
                }
            })
        }
        .sheet(item: $activeCall) { call in
            NativeAgentCallScreen(model: model, chatID: call.chatID, kind: call.kind, link: call.link) {
                if model.selectedID == call.chatID {
                    ForEach(model.selected.permissions) { permissionCard($0) }
                }
            }
        }
        .alert("Voice call unavailable", isPresented: Binding(
            get: { voiceError != nil }, set: { if !$0 { voiceError = nil } }
        )) {
            Button("Voice settings") { pairingVoice = true }
            Button("Cancel", role: .cancel) {}
        } message: { Text(voiceError ?? "") }
        .task {
            if let id = initialChatID, id != model.target.mainSessionID {
                if !model.sessions.contains(where: { $0.id == id }) {
                    await model.showMain()
                    await model.refreshSessions()
                }
                if model.sessions.contains(where: { $0.id == id }) { await model.open(id) }
                else { couldNotOpen = true }
            } else {
                model.selectMain()
                landing = false
                await model.showMain()
            }
            guard !Task.isCancelled else { return }
            landing = false
            visit()
        }
        .onChange(of: model.selectedID) {
            showsCompletedToolCalls = false
            visit()
        }
        .onChange(of: model.selected.working) { showsCompletedToolCalls = false }
        .onChange(of: model.title) { visit() }
        .onChange(of: model.selected.loaded) { visit() }
        .onChange(of: scenePhase) {
            if scenePhase != .active { safariApproval.cancelTurn() }
        }
        .onDisappear {
            safariApproval.cancelTurn()
            workspace.leave(chatKey)
        }
    }

    private var safariAgent: SafariSSHAgent? {
        guard let profile = voiceRemote, let credential = remoteStore?.bearer(for: profile) else { return nil }
        return SafariSSHAgent(profile: profile, credential: credential)
    }

    private func openAgentLink(_ url: URL) {
        guard url.scheme?.lowercased() == "https", let agent = safariAgent else {
            openURL(url)
            return
        }
        let chatID = model.selectedID
        Task {
            let launch = await safariApproval.launchURL(for: url, agent: agent, chatID: chatID) {
                model.selectedID == chatID
            }
            guard model.selectedID == chatID else { return }
            openURL(launch ?? url)
        }
    }

    private func sendMessage(_ text: String) {
        guard safariApproval.pending != nil, let agent = safariAgent else { model.submit(text); return }
        let chatID = model.selectedID
        model.submit(text) {
            await safariApproval.prepareTurn(agent: agent, chatID: chatID, stillInChat: {
                model.selectedID == chatID && !model.selected.stopping
            }, turnWorking: {
                model.selected.working
            }, resume: { openURL($0) })
        }
    }

    private var chat: some View {
        let chatKey = self.chatKey
        return ZStack {
            transcript.id(model.selectedID)
                .opacity(awaitingHistory ? 0 : 1)
                .accessibilityHidden(awaitingHistory || pickerIsOpen)
                .allowsHitTesting(!awaitingHistory)
            if awaitingHistory {
                ChatHistorySkeleton().transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: awaitingHistory)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !resolvingInitialChat {
                VStack(spacing: 0) {
                    if let error = safariApproval.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                            .accessibilityIdentifier("safari-chat-status")
                    }
                    ChatComposer(
                        model: model,
                        chatID: chatKey.chat,
                        draft: Binding(
                            get: { workspace.drafts[chatKey] },
                            set: { workspace.drafts[chatKey] = $0 }
                        ),
                        modelPickerVisible: $showModelPicker,
                        transcribe: dictationTranscriber,
                        didSend: {
                            showModelPicker = false
                            workspace.rememberReadingOffset(nil, for: chatKey)
                            viewport.restore(nil)
                        },
                        submit: sendMessage
                    )
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
            }
        }
        .overlay(alignment: .bottom) {
            if pickerIsOpen {
                ZStack(alignment: .bottom) {
                    Button {
                        showModelPicker = false
                    } label: {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss model controls")
                    .accessibilityIdentifier("dismiss-model-picker")

                    QuickModelPicker(model: model, sessionID: model.selectedID) {
                        showModelPicker = false
                        showAdvancedModelPicker = true
                    }
                    .padding(.bottom, 4)
                }
                .padding(.bottom, composerHeight)
                .transition(.opacity)
                .accessibilityAction(.escape) { showModelPicker = false }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: pickerIsOpen)
    }

    private func visit() {
        if !landing, !couldNotOpen, model.selected.loaded { workspace.visit(chatKey, title: model.title) }
    }

    private struct BrowserHandoff: Identifiable {
        let id = UUID()
        let remote: RemoteProfile
        let credential: String
        let chatID: String
        let request: PermissionRequest?
    }

    private func openBrowser(_ remote: RemoteProfile, credential: String, request: PermissionRequest? = nil) {
        browserHandoff = BrowserHandoff(remote: remote, credential: credential, chatID: model.selectedID, request: request)
    }

    private func browserCompletion(in request: PermissionRequest) -> PermissionRequest.Option? {
        guard request.toolCallID?.hasPrefix("clarify-") == true, request.options.count == 2,
              request.options.contains(where: { $0.id == "skip" && $0.kind == "reject_once" }) else { return nil }
        return request.options.first { $0.id == "choice-0" && $0.kind == "allow_once" && $0.name == "Browser handoff complete" }
    }

    private struct ChatCall: Identifiable {
        let id = UUID()
        let chatID: String
        let kind: RemoteKind
        let link: NativeVoiceLink
    }

    private func startCall() {
        guard let voiceRemote, let remoteStore, model.selected.loaded, activeCall == nil else { return }
        guard remoteStore.voice(for: voiceRemote) != nil else { pairingVoice = true; return }
        do {
            let link = try remoteStore.voiceLink(for: voiceRemote)
            activeCall = ChatCall(chatID: model.selectedID, kind: voiceRemote.kind, link: link)
        } catch {
            voiceError = error.localizedDescription
        }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if model.selected.loaded && model.selected.transcript.entries.isEmpty {
                    Text("Start a conversation")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                        .accessibilityIdentifier("empty-chat")
                }
                ForEach(model.selected.transcript.visibleEntries(showCompletedToolCalls: showsCompletedToolCalls)) { entry in
                    switch entry.content {
                    case .message(.user, let text):
                        TranscriptUserMessage(text: text, receipt: entry.receipt)
                    case .message(.assistant, let text):
                        ChatMarkdown(
                            source: text,
                            streaming: model.selected.working && !transcriptEndsWithRunningTool &&
                                model.selected.transcript.latestAssistantEntryID == entry.id,
                            openLink: openAgentLink
                        )
                    case .tool(let activity):
                        toolRow(activity)
                    }
                }
                ForEach(model.selected.permissions) { request in
                    permissionCard(request)
                }
                if let error = model.selected.error {
                    Text(error).font(.footnote)
                    if !model.selected.loaded {
                        Button("Try again") { Task { await model.open(model.selectedID) } }
                    }
                }
                if let notice = model.selected.notice {
                    Text(notice).font(.footnote).foregroundStyle(.secondary)
                }
                if !model.selected.plan.isEmpty {
                    TurnPlanCard(steps: model.selected.plan)
                }
                if model.selected.working {
                    let calls = model.selected.transcript.activeToolCalls
                    let current = calls.last { $0.status == nil || $0.status == "in_progress" || $0.status == "pending" }
                    LiveTurnActivity(
                        currentTool: current.map { $0.title ?? "Tool call" },
                        hasActivity: !calls.isEmpty
                    ) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(calls, id: \.id) { toolRow($0) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .transcriptColumn()
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("chat-transcript")
        .transcriptViewport($viewport, chat: model.selected.loaded ? chatKey : nil, showsJumpToLatest: !pickerIsOpen)
    }

    private var transcriptEndsWithRunningTool: Bool {
        guard let entry = model.selected.transcript.entries.last, case .tool(let tool) = entry.content else { return false }
        return tool.status == "in_progress"
    }

    private func toolRow(_ activity: ToolActivity) -> some View {
        let status = switch activity.status {
        case "pending": "Queued"
        case "in_progress": "Running"
        case "completed": "Done"
        case "failed": "Stopped"
        default: activity.status ?? "Updated"
        }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: activity.status == "completed" ? "checkmark" : "terminal")
                .accessibilityHidden(true)
            Text(activity.title ?? "Tool").fontWeight(.medium)
            Text("·").accessibilityHidden(true)
            Text(status)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-tool-call")
    }

    @ViewBuilder
    private func permissionCard(_ request: PermissionRequest) -> some View {
        if let remote = voiceRemote, remote.canOpenHermesScreen,
           let credential = remoteStore?.bearer(for: remote), browserCompletion(in: request) != nil {
            browserRequestCard(request, remote: remote, credential: credential)
        } else {
            approvalCard(request)
        }
    }

    private func approvalCard(_ request: PermissionRequest) -> some View {
        let actions = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        let shape = RoundedRectangle(cornerRadius: 14)
        return VStack(alignment: .leading, spacing: 8) {
            Label("Approval requested", systemImage: "lock.shield.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ChatTheme.attention)
            Text(request.title).font(.subheadline).foregroundStyle(.secondary)
            actions {
                ForEach(request.options.filter { ["allow_once", "reject_once"].contains($0.kind) }) { option in
                    Button(option.name) { Task { await model.answer(request, optionID: option.id) } }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("approval-\(option.kind)")
                }
                if !request.options.contains(where: { $0.kind == "reject_once" }) {
                    Button("Cancel request") { Task { await model.answer(request, optionID: nil) } }
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(ChatTheme.surface, in: shape)
        .overlay { shape.strokeBorder(ChatTheme.border, lineWidth: 0.5) }
        .disabled(model.selected.stopping)
    }

    private func browserRequestCard(_ request: PermissionRequest, remote: RemoteProfile, credential: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Browser handoff", systemImage: "macwindow")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ChatTheme.attention)
            Text(request.title).font(.subheadline).foregroundStyle(.secondary)
            Button("Open Hermes browser") { openBrowser(remote, credential: credential, request: request) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("hermes-browser-request")
            Button("Skip", role: .cancel) { Task { await model.answer(request, optionID: "skip") } }
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .disabled(model.selected.stopping)
    }

}
