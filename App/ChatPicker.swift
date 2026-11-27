import RiptideCore
import SwiftUI

struct ChatPicker: View {
    private static let compactDetent = PresentationDetent.height(310)

    let agent: WorkspaceAgent
    let openRoute: (WorkspaceRoute) -> Void
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var searching: Bool
    @State private var search = ""
    @State private var detent = compactDetent
    @State private var loading = true
    @State private var creating = false
    @State private var failure: String?

    private var isCodex: Bool { agent.id == WorkspaceState.localID || workspace.profile(agent.id)?.kind == .codex }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, ChatTheme.gutter)
                .padding(.top, 14)
                .padding(.bottom, 16)

            ScrollView {
                chatList
                    .padding(.horizontal, ChatTheme.gutter)
                    .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await loadChats() }
            .accessibilityIdentifier("chat-picker-list")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(ChatTheme.ink)
        .presentationBackground(ChatTheme.background)
        .presentationDetents([Self.compactDetent, .large], selection: $detent)
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
        .onChange(of: dynamicTypeSize, initial: true) {
            if dynamicTypeSize.isAccessibilitySize { detent = .large }
        }
        .onChange(of: searching) {
            if searching { detent = .large }
        }
        .task { await loadChats() }
        .task(id: creating) {
            if creating { await createChat() }
        }
    }

    private var header: some View {
        let controls = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Side chats")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text(workspace.agent(agent.id)?.name ?? agent.name)
                        .font(.subheadline)
                        .foregroundStyle(ChatTheme.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(ChatTheme.surface, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close chats")
                .accessibilityIdentifier("close-chats")
            }

            controls {
                searchField
                newChatButton
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ChatTheme.muted)
                .accessibilityHidden(true)
            TextField("Find a chat", text: $search, prompt: Text("Find a chat").foregroundStyle(ChatTheme.muted))
                .font(.subheadline)
                .frame(minHeight: 48)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($searching)
                .onSubmit { searching = false }
                .accessibilityIdentifier("chat-picker-search")
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(ChatTheme.muted)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, -8)
                .accessibilityLabel("Clear chat search")
            }
        }
        .padding(.horizontal, 12)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(ChatTheme.surface)
                .onTapGesture { searching = true }
                .accessibilityHidden(true)
        }
    }

    private var newChatButton: some View {
        Button {
            if isCodex { openRoute(.init(workspace: agent.id, startsNewChat: true)) }
            else { creating = true }
        } label: {
            HStack(spacing: 7) {
                if creating {
                    ProgressView().controlSize(.small).tint(ChatTheme.background)
                } else {
                    Image(systemName: "square.and.pencil")
                        .accessibilityHidden(true)
                }
                Text(creating ? "Starting…" : "New chat")
            }
            .font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .foregroundStyle(ChatTheme.background)
            .background(ChatTheme.ink, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(creating)
        .accessibilityIdentifier("new-chat")
    }

    private var chatList: some View {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let sideChats = workspace.sideChats(for: agent.id).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        let status = Dictionary(uniqueKeysWithValues: workspace.inboxRows.map { ($0.chat, $0.reason) })

        return LazyVStack(alignment: .leading, spacing: 16) {
            if let failure {
                VStack(alignment: .leading, spacing: 8) {
                    Label(failure, systemImage: "exclamationmark.circle").foregroundStyle(ChatTheme.warning)
                    Button("Retry") { Task { await loadChats() } }
                }
                .font(.footnote)
                .padding(.horizontal, 12)
            }

            if !sideChats.isEmpty {
                LazyVStack(spacing: 2) {
                    ForEach(sideChats) { chat in
                        chatRow(chat, status: status[chat.id])
                    }
                }
            }

            if loading && sideChats.isEmpty {
                ProgressView("Loading chats…")
                    .font(.subheadline)
                    .padding(.horizontal, 12)
            } else if failure == nil && sideChats.isEmpty {
                if query.isEmpty {
                    Text("No side chats yet.")
                        .font(.subheadline)
                        .foregroundStyle(ChatTheme.muted)
                        .padding(.horizontal, 12)
                } else {
                    ContentUnavailableView.search(text: query)
                        .accessibilityIdentifier("chat-picker-no-results")
                }
            }
            if agent.id == WorkspaceState.localID, query.isEmpty {
                Button("Watch desktop turn", systemImage: "desktopcomputer") { openRoute(.init(workspace: agent.id)) }
                    .font(.subheadline)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 12)
                    .accessibilityIdentifier("watch-desktop-codex")
            }
        }
    }

    private func chatRow(_ chat: WorkspaceVisit, status: AttentionReason?) -> some View {
        Button {
            openRoute(.init(workspace: agent.id, chat: chat.id.chat))
        } label: {
            WorkspaceRow(title: chat.title, subtitle: status == .followUp ? "" : status?.title ?? "", symbol: "bubble.left")
                .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-chat-\(chat.id.chat)")
        .contextMenu { FollowUpButton(chat: chat.id, title: chat.title) }
    }

    private func loadChats() async {
        loading = true
        failure = nil
        defer { loading = false }
        if isCodex, let endpoint = workspace.codexEndpoint(for: agent.id) {
            let client = endpoint.makeClient()
            do {
                let chats = try await client.listSavedChats()
                try Task.checkCancellation()
                if let first = chats.first { workspace.useCodexMainChat(first.id, workspaceID: agent.id) }
                workspace.rememberCodexCatalog(chats, workspaceID: agent.id)
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
            await client.close()
        } else if !isCodex, let model = workspace.agentChatModel(for: agent.id) {
            await model.refreshSessions()
            if !Task.isCancelled { failure = model.listError }
        } else {
            failure = "Unlock this device or pair the remote again."
        }
    }

    private func createChat() async {
        defer { creating = false }
        guard let model = workspace.agentChatModel(for: agent.id) else {
            failure = "Unlock this device or pair the remote again."
            return
        }
        let id = await model.createSideChat(openClaw: workspace.profile(agent.id)?.kind == .openClaw)
        guard !Task.isCancelled else { return }
        if let id { openRoute(.init(workspace: agent.id, chat: id)) }
        else { failure = model.listError }
    }
}
