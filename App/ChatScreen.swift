import RiptideCore
import SwiftUI

struct ChatScreen: View {
    let model: AgentChatModel
    var voiceRemote: RemoteProfile? = nil
    var remoteStore: RemoteStore? = nil
    @State private var showChats = false
    @State private var drafts: [String: String] = [:]
    @State private var nearBottom = true
    @State private var pairingVoice = false
    @State private var activeCall: ChatCall?
    @State private var voiceError: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            transcript.id(model.selectedID)
            ChatComposer(
                model: model,
                draft: Binding(
                    get: { drafts[model.selectedID, default: ""] },
                    set: { drafts[model.selectedID] = $0 }
                ),
                didSend: { nearBottom = true }
            )
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
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(model.title).font(.headline).lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(model.target.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.title)
                .accessibilityValue(model.target.name)
                .accessibilityHint("Switch or start a chat")
                .accessibilityIdentifier("chats-button")
            }
            if voiceRemote != nil {
                ToolbarItem(placement: .topBarTrailing) {
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
        .sheet(isPresented: $pairingVoice) {
            if let voiceRemote, let remoteStore { PairNativeVoiceScreen(remote: voiceRemote, store: remoteStore) }
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
        .task { await model.showMain() }
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if model.selected.loading {
                        ProgressView("Opening chat…")
                    } else if model.selected.loaded && model.selected.transcript.entries.isEmpty {
                        Text("Start a conversation")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                            .accessibilityIdentifier("empty-chat")
                    }
                    ForEach(model.selected.transcript.entries) { entry in
                        switch entry.content {
                        case .message(.user, let text):
                            Text(text)
                                .textSelection(.enabled)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                                .padding(.leading, 28)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        case .message(.assistant, let text):
                            ChatMarkdown(
                                source: text,
                                streaming: model.selected.working && model.selected.transcript.latestAssistantEntryID == entry.id
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
                    if model.selected.working && model.selected.permissions.isEmpty {
                        Text("Working…").font(.footnote).foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 1).id("chat-bottom").accessibilityHidden(true)
                }
                .padding(20)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .scrollDismissesKeyboard(.interactively)
            .onAppear { nearBottom = true }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY < 110
            } action: { _, atBottom in
                nearBottom = atBottom
            }
            .onChange(of: model.selected.transcript.entries) {
                if nearBottom { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            .onChange(of: model.selected.permissions) {
                if nearBottom { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            .onChange(of: model.selected.working) {
                if nearBottom { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
        }
    }

    private func toolRow(_ activity: ToolActivity) -> some View {
        let status = switch activity.status {
        case "pending": "Queued"
        case "in_progress": "Running"
        case "completed": "Done"
        case "failed": "Stopped"
        default: activity.status ?? "Updated"
        }
        return HStack(spacing: 8) {
            Image(systemName: activity.status == "completed" ? "checkmark" : "terminal")
                .accessibilityHidden(true)
            Text(activity.title ?? "Tool")
            Text("·").accessibilityHidden(true)
            Text(status)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func permissionCard(_ request: PermissionRequest) -> some View {
        let actions = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        let shape = RoundedRectangle(cornerRadius: 14)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Approval requested").font(.subheadline.weight(.semibold))
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

}

private struct ChatPicker: View {
    let model: AgentChatModel
    let openClaw: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("Main Chat", id: model.target.mainSessionID)
                    ForEach(model.sessions.filter { $0.id != model.target.mainSessionID }) { session in
                        row(session.title, id: session.id)
                    }
                    if model.refreshingList { ProgressView("Loading chats…") }
                    if let error = model.listError {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(ChatTheme.background)
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { if await model.createChat(openClaw: openClaw) { dismiss() } }
                } label: {
                    Label(model.creatingChat ? "Starting…" : "New chat", systemImage: "square.and.pencil")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.creatingChat)
                .accessibilityIdentifier("new-chat")
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(ChatTheme.background)
            }
            .task { await model.refreshSessions() }
        }
    }

    private func row(_ title: String, id: String) -> some View {
        Button {
            Task { await model.open(id) }
            dismiss()
        } label: {
            HStack {
                Text(title)
                Spacer()
                if id == model.selectedID {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(id == model.selectedID ? .isSelected : [])
        .listRowBackground(ChatTheme.background)
    }
}
