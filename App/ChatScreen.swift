import RiptideCore
import SwiftUI

struct ChatScreen: View {
    let model: AgentChatModel
    var voiceRemote: RemoteProfile? = nil
    var remoteStore: RemoteStore? = nil
    var initialChatID: String? = nil
    @State private var showChats = false
    @State private var showModelPicker = false
    @State private var composerHeight: CGFloat = 0
    @State private var landing = true
    @State private var couldNotOpen = false
    @State private var openAttempt = 0
    @State private var viewport = TranscriptViewport()
    @State private var showsCompletedToolCalls = false
    @State private var pairingVoice = false
    @State private var activeCall: NativeAgentCall?
    @State private var voiceError: String?
    @State private var browserHandoff: BrowserHandoff?
    @State private var focusAfterHandback: String?
    @State private var connectingHermes: UUID?
    @State private var hermesPairingAttempt: HermesPairingAttempt?
    @State private var composerFocused = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(WorkspaceState.self) private var workspace

    private var agentName: String { workspace.agent(model.target.id)?.name ?? model.target.name }

    private var chatKey: WorkspaceChatID { .init(workspace: model.target.id, chat: model.selectedID) }
    private var dictationTranscriber: DictationTranscriber? {
        if let voiceRemote, let bearer = remoteStore?.bearer(for: voiceRemote),
           let dictation = voiceRemote.makeHermesDictation(credential: bearer) {
            return dictation.transcribe
        }
        return model.target.id == "hermes" ? DictationFixture.transcribe : nil
    }

    private var pickerIsOpen: Bool {
        showModelPicker && !resolvingInitialChat && composerSettings.hasChoices
    }

    private var composerSettings: ChatComposerSettings {
        let chatID = model.selectedID
        let chat = model.selected
        return .init(options: chat.configOptions, reportedModelName: chat.modelName, configuring: chat.configuring,
                     working: chat.working, error: chat.configError) { id, value in
            await model.setConfigOption(id, value: value, sessionID: chatID)
            return model.selectedID == chatID && model.selected.configOptions.contains { $0.id == id && $0.currentValue == value }
        }
    }

    private var hasVisiblePairingRequest: Bool {
        model.selected.permissions.contains { HermesPairingInvitation($0) != nil } && pairingConnector() != nil
    }

    private var resolvingInitialChat: Bool {
        landing && model.selectedID != (initialChatID ?? model.target.mainSessionID)
    }

    private var awaitingHistory: Bool {
        resolvingInitialChat || (!model.selected.loaded && !model.selected.connectionLost && model.selected.error == nil &&
                                 model.selected.transcript.entries.isEmpty && model.selected.permissions.isEmpty)
    }

    private var disconnectedChat: WorkspaceChatID? {
        guard scenePhase == .active, !landing, !couldNotOpen, model.selected.connectionLost else { return nil }
        return chatKey
    }

    var body: some View {
        VStack(spacing: 0) {
            if couldNotOpen {
                ContentUnavailableView {
                    Label("Chat unavailable", systemImage: "bubble.left")
                } description: {
                    Text(model.listError ?? "This connector didn’t list the saved chat.")
                } actions: {
                    Button("Retry") { openAttempt += 1 }
                        .buttonStyle(.borderedProminent)
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
                    WorkspaceChatHeading(title: model.title, workspaceName: agentName)
                }
                .buttonStyle(.plain)
                .workspaceFlickNavigation(model.target.id)
                .accessibilityLabel(model.title)
                .accessibilityValue(agentName)
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
                    if workspace.supportsHermesGroups(model.target.id) {
                        Button("Group chats", systemImage: "person.2") { workspace.showSidebar(.groups) }
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
                                guard remoteStore.hasVoiceRoute(for: voiceRemote) else { pairingVoice = true; return }
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
        .sheet(isPresented: $pairingVoice) {
            if let voiceRemote, let remoteStore { PairNativeVoiceScreen(remote: voiceRemote, store: remoteStore) }
        }
        .fullScreenCover(item: $browserHandoff, onDismiss: {
            if focusAfterHandback == model.selectedID { composerFocused = true }
            focusAfterHandback = nil
        }) { handoff in
            HermesScreen(remote: handoff.remote, credential: handoff.credential) {
                guard model.selectedID == handoff.chatID else { return }
                focusAfterHandback = handoff.chatID
                if let request = handoff.request, model.selected.permissions.contains(request),
                   let option = browserCompletion(in: request) {
                    Task { await model.answer(request, optionID: option.id) }
                }
            }
        }
        .fullScreenCover(item: $activeCall) { call in
            NativeAgentCallScreen(call: call, agent: workspace.agent(model.target.id)) {
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
        .task(id: openAttempt) {
            if let id = initialChatID, id != model.target.mainSessionID {
                landing = true
                couldNotOpen = false
                let opened = await model.openSavedChat(id)
                guard !Task.isCancelled else { return }
                couldNotOpen = !opened
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
            if !landing { couldNotOpen = false }
            showsCompletedToolCalls = false
            visit()
        }
        .onChange(of: model.selected.working) { showsCompletedToolCalls = false }
        .onChange(of: hasVisiblePairingRequest) {
            if hasVisiblePairingRequest, workspace.drafts[chatKey].isEmpty { composerFocused = false }
        }
        .onChange(of: model.title) { visit() }
        .onChange(of: model.selected.loaded) { visit() }
        .task(id: disconnectedChat) {
            if let disconnectedChat { await model.open(disconnectedChat.chat) }
        }
        .onDisappear {
            workspace.leave(chatKey)
        }
    }

    private func submitDraft(_ draft: Binding<String>, attachments: Binding<[ChatAttachment]>,
                             in chat: WorkspaceChatID, queue: Bool) {
        let message = ComposerDraft(text: draft, files: attachments)
        let selected = model.selected
        guard model.selectedID == chat.chat, selected.loaded, !selected.loading, !selected.configuring,
              !selected.stopping, !selected.steering, !selected.sendingAttachmentDraft, message.hasContent else { return }
        viewport.jumpToLatest()
        if queue || (selected.working && !message.attachments.isEmpty) {
            if model.enqueue(message.text, attachments: message.attachments, in: chat.chat) { message.clear() }
        } else if selected.working {
            Task {
                if await model.steer(message.text, in: chat.chat) { message.clear() }
            }
        } else if message.attachments.isEmpty {
            if model.submit(message.text) { message.clear() }
        } else {
            _ = model.submit(message.text, attachments: message.attachments, onWritten: message.clear,
                             onRejected: message.restoreIfEmpty)
        }
    }

    private var chat: some View {
        let chatKey = self.chatKey
        let settings = resolvingInitialChat ? ChatComposerSettings() : composerSettings
        let selected = model.selected
        let attachments = Binding(get: { workspace.drafts[attachments: chatKey] },
                                  set: { workspace.drafts[attachments: chatKey] = $0 })
        let canSteer = selected.canSteer && attachments.wrappedValue.isEmpty
        let submission: ChatComposer.Submission = canSteer ? .steer : selected.working ? .queue : .send
        let prompt = switch submission {
        case .send: "Message \(agentName)"
        case .steer: "Steer this reply"
        case .queue: "Queue a message"
        }
        let draft = Binding(get: { workspace.drafts[chatKey] }, set: { workspace.drafts[chatKey] = $0 })
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
                    ComposerQueue(messages: selected.queuedMessages, sendingID: selected.sendingQueuedID,
                                  paused: model.selected.queuePaused, canResume: model.selected.loaded,
                                  remove: { model.removeQueuedMessage($0, in: chatKey.chat) },
                                  resume: { model.resumeQueue(in: chatKey.chat) })
                    if let error = model.selected.steeringError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                            .accessibilityIdentifier("chat-steering-status")
                    }
                    ChatComposer(
                        prompt: prompt,
                        chatID: chatKey.chat,
                        draft: draft,
                        attachments: attachments,
                        modelPickerVisible: $showModelPicker,
                        editorFocus: $composerFocused,
                        acceptsImages: selected.acceptsImages,
                        attachmentByteLimit: ChatAttachment.acpByteLimit,
                        privateFileTransfer: workspace.privateFileTransfer(for: chatKey.workspace),
                        settings: settings,
                        context: selected.context,
                        ready: selected.loaded,
                        canDictate: selected.loaded,
                        canSubmit: selected.loaded && !selected.loading && !selected.configuring
                            && !selected.stopping && !selected.steering && !selected.sendingAttachmentDraft,
                        transcribe: dictationTranscriber,
                        submission: submission, stopping: selected.stopping,
                        stop: selected.canStop ? { Task { await model.stop() } } : nil,
                        enqueue: canSteer ? { submitDraft(draft, attachments: attachments, in: chatKey, queue: true) } : nil
                    ) {
                        submitDraft(draft, attachments: attachments, in: chatKey, queue: submission == .queue)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
            }
        }
        .modifier(ChatModelPicker(settings: settings, composerHeight: composerHeight,
                                  chatID: chatKey.chat, isExpanded: $showModelPicker))
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
        composerFocused = false
        browserHandoff = BrowserHandoff(remote: remote, credential: credential, chatID: model.selectedID, request: request)
    }

    private func browserCompletion(in request: PermissionRequest) -> PermissionRequest.Option? {
        guard request.toolCallID?.hasPrefix("clarify-") == true, request.options.count == 2,
              request.options.contains(where: { $0.id == "skip" && $0.kind == "reject_once" }) else { return nil }
        return request.options.first { $0.id == "choice-0" && $0.kind == "allow_once" && $0.name == "Browser handoff complete" }
    }

    private func startCall() {
        guard let voiceRemote, let remoteStore, model.selected.loaded, activeCall == nil else { return }
        if let call = NativeCallSystem.shared.call(for: model, chatID: model.selectedID) {
            activeCall = call
            return
        }
        guard remoteStore.hasVoiceRoute(for: voiceRemote) else { pairingVoice = true; return }
        do {
            let link = try remoteStore.voiceLink(for: voiceRemote)
            activeCall = NativeAgentCall(name: agentName, model: model, chatID: model.selectedID, link: link)
        } catch {
            voiceError = error.localizedDescription
        }
    }

    private var transcript: some View {
        let latestUserMessageID = model.selected.transcript.latestUserMessageID
        return ScrollView {
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
                        TranscriptUserMessage(text: text, photos: entry.photos,
                                              receipt: entry.id == latestUserMessageID ? entry.receipt : nil)
                    case .message(.assistant, let text):
                        ChatMarkdown(
                            source: text,
                            streaming: !entry.isAssistantProgress && model.selected.working && !transcriptEndsWithRunningTool &&
                                model.selected.transcript.latestAssistantEntryID == entry.id,
                            openLink: { openURL($0) }
                        )
                    case .tool(let activity):
                        toolRow(activity)
                    case .contextCompaction(let compaction):
                        ContextCompactionLine(compaction: compaction)
                    case .pairingReceipt(let name, let connected):
                        AgentPairingReceipt(name: name, connected: connected)
                    }
                }
                ForEach(model.selected.permissions) { request in
                    permissionCard(request)
                }
                if model.selected.connectionLost && model.selected.loading {
                    Text("Reconnecting…").font(.footnote).foregroundStyle(.secondary)
                } else if let error = model.selected.error {
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
                if model.selected.working && !hasVisiblePairingRequest {
                    if let compaction = model.selected.transcript.activeCompaction {
                        ContextCompactionLine(compaction: compaction)
                    } else {
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
            }
            .transcriptColumn()
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("chat-transcript")
        .transcriptViewport($viewport, chat: model.selected.loaded ? chatKey : nil,
                            composerFocused: composerFocused, showsJumpToLatest: !pickerIsOpen)
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
        if let invitation = HermesPairingInvitation(request), let connector = pairingConnector(for: request.id) {
            AgentPairingCard(
                name: invitation.displayName,
                connecting: connectingHermes == request.id,
                isDisabled: model.selected.stopping || connectingHermes != nil,
                error: hermesPairingAttempt?.requestID == request.id ? hermesPairingAttempt?.error : nil
            ) {
                connectHermes(request, invitation: invitation, connector: connector)
            } skip: {
                if hermesPairingAttempt?.requestID == request.id { hermesPairingAttempt = nil }
                Task { await model.answerPairing(request, connectedName: nil) }
            }
        } else if let remote = voiceRemote, remote.canOpenHermesScreen,
                  let credential = remoteStore?.bearer(for: remote), browserCompletion(in: request) != nil {
            browserRequestCard(request, remote: remote, credential: credential)
        } else {
            approvalCard(request)
        }
    }

    private struct HermesPairingAttempt {
        let requestID: UUID
        var identity = SSHDeviceIdentity()
        var error: String?
    }

    private typealias PairingConnector = @MainActor (HermesPairingInvitation, SSHDeviceIdentity) async throws -> String

    private func pairingConnector(for requestID: UUID? = nil) -> PairingConnector? {
        #if DEBUG
        if model.target.id == "hermes", AgentPairingFixture.isEnabled {
            let retrying = hermesPairingAttempt?.requestID == requestID && hermesPairingAttempt?.error != nil
            return { invitation, _ in try await AgentPairingFixture.connect(invitation, retrying: retrying) }
        }
        #endif
        guard let store = remoteStore, let source = voiceRemote, source.canOpenHermesScreen,
              let credential = store.bearer(for: source) else { return nil }
        return { invitation, identity in
            let remote = try await source.authorizeHermesPairing(invitation, credential: credential, identity: identity)
            try await store.pair(remote, credential: identity.privateCredential)
            return remote.name
        }
    }

    private func connectHermes(_ request: PermissionRequest, invitation: HermesPairingInvitation,
                               connector: @escaping PairingConnector) {
        guard connectingHermes == nil, model.selected.permissions.contains(request) else { return }
        let previous = hermesPairingAttempt.flatMap { $0.requestID == request.id ? $0 : nil }
        let attempt = previous ?? HermesPairingAttempt(requestID: request.id)
        hermesPairingAttempt = HermesPairingAttempt(requestID: request.id, identity: attempt.identity)
        connectingHermes = request.id
        Task {
            defer { connectingHermes = nil }
            do {
                let name = try await connector(invitation, attempt.identity)
                hermesPairingAttempt = nil
                await model.answerPairing(request, connectedName: name)
            } catch {
                hermesPairingAttempt = HermesPairingAttempt(requestID: request.id, identity: attempt.identity,
                                                            error: error.localizedDescription)
            }
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
