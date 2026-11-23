import RiptideCore
import SwiftUI

struct CodexChatsScreen: View {
    let endpoint: CodexLocalEndpoint
    let name: String
    private let opensLastChat: Bool
    @AppStorage private var lastChat: String
    @State private var chats: [CodexChatSummary] = []
    @State private var selected: CodexChatSummary?
    @State private var loading = false
    @State private var didOpen = false
    @State private var failure: String?
    @State private var newChat = false
    @State private var directCall = false

    init(endpoint: CodexLocalEndpoint, name: String, selectionKey: String? = nil) {
        self.endpoint = endpoint
        self.name = name
        opensLastChat = selectionKey != nil
        _lastChat = AppStorage(wrappedValue: "", "codex.last-chat.\(selectionKey ?? "local-test")")
    }

    var body: some View {
        List {
            if chats.isEmpty && !loading && failure == nil {
                Text("No saved chats in this workspace.").foregroundStyle(.secondary)
            }
            ForEach(chats) { chat in
                Button { selected = chat } label: {
                    Label(chat.title, systemImage: "bubble.left")
                }
                .accessibilityIdentifier("codex-saved-chat")
            }
            if loading { ProgressView("Opening chats…") }
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(.secondary)
                Button("Retry") { Task { await load() } }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(ChatTheme.background)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Call Codex directly", systemImage: "phone") { directCall = true }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("call-codex-direct")
                Button("New chat", systemImage: "square.and.pencil") { newChat = true }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("new-codex-chat")
            }
        }
        .sheet(isPresented: $directCall) { CodexVoiceScreen(endpoint: endpoint) }
        .navigationDestination(item: $selected) { chat in
            CodexSavedChatScreen(endpoint: endpoint, initialChat: chat) { lastChat = $0.id }
        }
        .navigationDestination(isPresented: $newChat) {
            CodexSavedChatScreen(endpoint: endpoint, initialChat: nil) { chat in
                lastChat = chat.id
                if !chats.contains(where: { $0.id == chat.id }) { chats.insert(chat, at: 0) }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        failure = nil
        let client = endpoint.makeClient()
        do {
            chats = try await client.listSavedChats()
            if opensLastChat && !didOpen {
                didOpen = true
                selected = chats.first { $0.id == lastChat }
            }
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
        await client.close()
        loading = false
    }
}

private struct CodexSavedChatScreen: View {
    let endpoint: CodexLocalEndpoint
    let initialChat: CodexChatSummary?
    let onOpen: (CodexChatSummary) -> Void
    @State private var chat: CodexChatSummary?
    @State private var client: CodexLiveClient?
    @State private var messages: [CodexChatMessage] = []
    @State private var approvals: [CodexChatApproval] = []
    @State private var responding = Set<UUID>()
    @State private var ready = false
    @State private var working = false
    @State private var sending = false
    @State private var attempt = 0
    @State private var draft = ""
    @State private var issue: String?
    @State private var showCall = false
    @State private var hasOlderTurns = false
    @State private var diff: String?
    @State private var nearBottom = true

    var body: some View {
        VStack(spacing: 0) {
            transcript
            if ready { composer }
        }
        .background(ChatTheme.background)
        .navigationTitle(chat?.title ?? initialChat?.title ?? "New chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Call in this chat", systemImage: "phone") { showCall = true }
                    .labelStyle(.iconOnly)
                    .disabled(!ready || chat == nil)
                    .accessibilityIdentifier("call-codex-in-chat")
            }
        }
        .sheet(isPresented: $showCall) {
            if let chat, let client { CodexVoiceScreen(endpoint: endpoint, chat: chat, client: client) }
        }
        .task(id: attempt) { await watch() }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if hasOlderTurns {
                        Text("Showing the latest 30 turns.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(messages) { message in
                        if message.role == .assistant {
                            ChatMarkdown(source: message.text, streaming: message.streaming)
                        } else {
                            Text(message.text)
                                .textSelection(.enabled)
                                .padding(12)
                                .background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                                .padding(.leading, 30)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    if let diff {
                        DisclosureGroup("Changes") { DiffPreview(source: diff, title: "Turn diff") }
                    }
                    ForEach(approvals) { approval in approvalCard(approval) }
                    if let issue {
                        Text(issue).font(.footnote).foregroundStyle(.secondary)
                        if !ready { Button("Reconnect") { attempt += 1 } }
                    } else if !ready {
                        ProgressView("Opening chat…")
                    } else if messages.isEmpty && !working {
                        Text("Start a conversation").foregroundStyle(.secondary)
                    }
                    if working { Text("Working…").font(.footnote).foregroundStyle(.secondary) }
                    Color.clear.frame(height: 1).id("codex-saved-bottom").accessibilityHidden(true)
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY < 110
            } action: { _, atBottom in nearBottom = atBottom }
            .onChange(of: messages) {
                if nearBottom { proxy.scrollTo("codex-saved-bottom", anchor: .bottom) }
            }
            .onChange(of: approvals) {
                if nearBottom { proxy.scrollTo("codex-saved-bottom", anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField(working ? "Steer this turn" : "Message Codex", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
            Button(working ? "Steer" : "Send") { Task { await send() } }
                .buttonStyle(.borderedProminent)
                .padding(.trailing, 6)
                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .contentPanel()
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func approvalCard(_ approval: CodexChatApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Approval requested").font(.subheadline.weight(.semibold))
            if let reason = approval.reason { Text(reason).font(.footnote) }
            if let command = approval.command { CodePreview(source: command, language: "shell") }
            if let cwd = approval.cwd { Text(cwd).font(.caption).foregroundStyle(.secondary) }
            if !approval.canAllow { Text("Review this action in Codex on the host.").font(.footnote) }
            HStack {
                if approval.canAllow {
                    Button("Allow once") { answer(approval, allow: true) }.buttonStyle(.bordered)
                }
                if approval.canDecline {
                    Button("Decline") { answer(approval, allow: false) }.buttonStyle(.bordered)
                }
            }
            .disabled(responding.contains(approval.id))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .contentPanel()
    }

    private func watch() async {
        let peer = endpoint.makeClient()
        ready = false
        approvals = []
        responding = []
        issue = nil
        client = peer
        do {
            if let existing = chat ?? initialChat {
                let snapshot = try await peer.openSavedChat(existing.id)
                messages = snapshot.messages
                working = snapshot.working
                hasOlderTurns = snapshot.hasOlderTurns
                chat = existing
            } else {
                chat = try await peer.createSavedChat()
            }
            try Task.checkCancellation()
            if let chat { onOpen(chat) }
            ready = true
            for try await event in peer.chatEvents { apply(event) }
            if !Task.isCancelled { issue = "Connection closed." }
        } catch {
            if !Task.isCancelled { issue = error.localizedDescription }
        }
        if client === peer {
            ready = false
            working = false
            approvals = []
            responding = []
            client = nil
        }
        await peer.close()
    }

    private func apply(_ event: CodexChatEvent) {
        switch event {
        case .message(let message):
            upsert(message)
        case .turnStarted:
            working = true
            diff = nil
        case .approval(let approval):
            approvals.append(approval)
        case .approvalResolved(let id):
            approvals.removeAll { $0.id == id }
            responding.remove(id)
        case .live(let update):
            switch update {
            case .assistantDelta(_, let item, let text):
                if let index = messages.firstIndex(where: { $0.id == item }) {
                    if messages[index].streaming { messages[index].text += text }
                } else {
                    messages.append(CodexChatMessage(id: item, role: .assistant, text: text, streaming: true))
                }
            case .assistantCompleted(_, let item, let text):
                upsert(CodexChatMessage(id: item, role: .assistant, text: text, streaming: false))
            case .completed:
                working = false
                for index in messages.indices { messages[index].streaming = false }
            case .diff(_, let patch):
                diff = patch.isEmpty ? nil : patch
            case .output:
                break
            }
        }
    }

    private func upsert(_ message: CodexChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, ready, !sending, !text.isEmpty else { return }
        sending = true
        issue = nil
        defer { sending = false }
        do {
            try await client.sendToSavedChat(text)
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
        } catch {
            issue = error.localizedDescription
        }
    }

    private func answer(_ approval: CodexChatApproval, allow: Bool) {
        guard let client, ready, responding.insert(approval.id).inserted else { return }
        Task {
            do { try await client.answer(approval, allow: allow) }
            catch {
                issue = error.localizedDescription
                responding.remove(approval.id)
            }
        }
    }
}
