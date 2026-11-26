import RiptideCore
import SwiftUI
import UIKit

struct WorkspaceSidebar: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var editing = false
    @State private var creatingGroup = false

    private var title: String {
        switch workspace.sidebarTab {
        case .inbox: "Inbox"
        case .agents: "Agents"
        case .groups: "Group chats"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header(title: title)
            content
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    WorkspaceTabBar(selected: workspace.sidebarTab)
                }
        }
        .frame(maxWidth: ChatTheme.readingWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ChatTheme.background.ignoresSafeArea())
        .navigationTitle("Workspaces")
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $editing) { WorkspaceEditor().environment(workspace) }
    }

    @ViewBuilder
    private var content: some View {
        switch workspace.sidebarTab {
        case .inbox:
            WorkspaceInboxList().id(workspace.inboxReset)
        case .agents:
            AgentGrid()
        case .groups:
            HermesGroupCatalog(sources: workspace.hermesGroupSources, creating: $creatingGroup)
        }
    }

    private func header(title: String) -> some View {
        HStack(alignment: .center, spacing: 4) {
            Text(title)
                .font(.largeTitle.weight(.semibold))
                .lineLimit(2)
                .layoutPriority(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("sidebar-heading")
            Spacer(minLength: 6)
            if workspace.sidebarTab == .inbox {
                sidebarAction("Notification settings", symbol: "bell") { workspace.showingAlerts = true }
                    .accessibilityIdentifier("inbox-notifications")
            }
            if workspace.sidebarTab == .groups {
                if !workspace.hermesGroupSources.isEmpty {
                    sidebarAction("New group chat", symbol: "plus") { creatingGroup = true }
                        .accessibilityIdentifier("new-hermes-group")
                }
            } else {
                sidebarAction("Manage agents", symbol: "pencil") { editing = true }
                    .accessibilityIdentifier("edit-roster")
            }
        }
        .foregroundStyle(ChatTheme.ink)
        .padding(.leading, ChatTheme.gutter)
        .padding(.trailing, ChatTheme.gutter - 4)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func sidebarAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.medium))
                .frame(width: 34, height: 34)
                .background(ChatTheme.surface, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct AgentWorkspaceScreen: View {
    let agent: WorkspaceAgent
    @Environment(WorkspaceState.self) private var workspace
    @State private var loading = true
    @State private var failure: String?
    @State private var voiceEndpoint: CodexLocalEndpoint?
    @State private var showingCall = false
    @State private var editingPhoto = false

    private var isCodex: Bool { agent.id == WorkspaceState.localID || workspace.profile(agent.id)?.kind == .codex }

    var body: some View {
        let chats = workspace.sidebarChats(for: agent.id)
        List {
            if let main = workspace.mainChatID(for: agent.id) {
                Section {
                    chatRow(.init(id: .init(workspace: agent.id, chat: main), title: "Main Chat"),
                            identifier: "sidebar-main-chat", isMain: true)
                }
                .listSectionSeparator(.hidden)
            }
            Section {
                ForEach(chats) { chat in
                    chatRow(chat, identifier: "sidebar-chat-\(chat.id.chat)", divider: chat.id != chats.last?.id)
                }
                if loading && chats.isEmpty {
                    ProgressView("Loading chats…").sidebarRowStyle()
                } else if let failure {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(failure).font(.footnote).foregroundStyle(ChatTheme.muted)
                        Button("Retry") { Task { await reload() } }
                    }
                    .sidebarRowStyle()
                } else if chats.isEmpty {
                    Text(isCodex ? "No saved chats yet." : "No side chats yet.")
                        .font(.subheadline)
                        .foregroundStyle(ChatTheme.muted)
                        .sidebarRowStyle()
                }
            } header: {
                HStack {
                    SidebarSectionTitle(isCodex ? "Chats" : "Side chats")
                    Spacer()
                    if isCodex, let endpoint = workspace.codexEndpoint(for: agent.id) {
                        Menu {
                            Button("New chat", systemImage: "square.and.pencil") { workspace.startCodexChat(agent.id) }
                            Button("Call Codex directly", systemImage: "phone") {
                                voiceEndpoint = endpoint
                                showingCall = true
                            }
                        } label: {
                            Label("Codex actions", systemImage: "ellipsis")
                                .labelStyle(.iconOnly)
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                    }
                }
                .sidebarHeaderStyle()
            }
            .listSectionSeparator(.hidden)
            if agent.id == WorkspaceState.localID {
                Button("Watch desktop turn", systemImage: "desktopcomputer") {
                    workspace.open(agent.id, resume: false)
                }
                .font(.subheadline)
                .accessibilityIdentifier("watch-desktop-codex")
                .sidebarRowStyle()
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(12)
        .scrollContentBackground(.hidden)
        .background(ChatTheme.background)
        .navigationTitle(agent.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    editingPhoto = true
                } label: {
                    HStack(spacing: 8) {
                        AgentAvatar(agent: agent, size: 30)
                        Text(agent.name).font(.headline).lineLimit(1)
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Edit profile photo")
                .accessibilityIdentifier("agent-workspace-heading")
            }
        }
        .sheet(isPresented: $editingPhoto) {
            AgentAvatarEditor(agent: agent).environment(workspace)
        }
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(isPresented: $showingCall) {
            if let voiceEndpoint { CodexVoiceScreen(endpoint: voiceEndpoint) }
        }
    }

    private func chatRow(_ chat: WorkspaceVisit, identifier: String, isMain: Bool = false, divider: Bool = false) -> some View {
        let status = workspace.inboxRows.first { $0.chat == chat.id && $0.reason != .followUp }?.reason.title
        return Button {
            workspace.open(chat.id.workspace, chat: chat.id.chat)
        } label: {
            WorkspaceRow(title: chat.title, subtitle: status ?? "", symbol: isMain ? "bubble.left.fill" : "bubble.left",
                         color: isMain ? ChatTheme.sidebarAccent : ChatTheme.muted, featured: isMain)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .contextMenu { FollowUpButton(chat: chat.id, title: chat.title) }
        .sidebarRowStyle(divider: divider)
    }

    private func reload() async {
        loading = true
        failure = nil
        defer { loading = false }
        if let endpoint = workspace.codexEndpoint(for: agent.id) {
            let client = endpoint.makeClient()
            do {
                let chats = try await client.listSavedChats()
                try Task.checkCancellation()
                workspace.rememberCodexCatalog(chats, workspaceID: agent.id)
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
            await client.close()
        } else if let model = workspace.sidebarACPModel(for: agent.id) {
            await model.refreshSessions()
            if !Task.isCancelled { failure = model.listError }
        } else {
            failure = "Unlock this device or pair the remote again."
        }
    }
}

struct SidebarSectionTitle: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(ChatTheme.ink)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, 4)
    }
}

extension View {
    func sidebarHeaderStyle() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: ChatTheme.gutter, bottom: 0, trailing: ChatTheme.gutter))
    }

    func sidebarRowStyle(divider: Bool = false) -> some View {
        listRowInsets(EdgeInsets(top: 5, leading: ChatTheme.gutter, bottom: 5, trailing: ChatTheme.gutter))
            .listRowBackground(ChatTheme.background)
            .listRowSeparator(.hidden, edges: .top)
            .listRowSeparator(divider ? .visible : .hidden, edges: .bottom)
            .listRowSeparatorTint(ChatTheme.sidebarDivider, edges: .bottom)
            .alignmentGuide(.listRowSeparatorLeading) { _ in WorkspaceRow.textInset }
    }
}

private struct WorkspaceEditor: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = false
    @State private var forgetting: RemoteProfile?
    @State private var issue: String?

    private var pins: Binding<[String]> {
        Binding(get: { workspace.demoPins }, set: { workspace.setDemoPins($0) })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Pair remote", systemImage: "plus") { pairing = true }
                        .accessibilityIdentifier("pair-remote")
                    if !workspace.roster.isEmpty && !workspace.remotes.profiles.isEmpty {
                        Toggle("Show demo agents", isOn: Binding(
                            get: { workspace.showDemoAgents }, set: { workspace.setShowDemoAgents($0) }
                        ))
                    }
                    if let issue { Text(issue).font(.footnote).foregroundStyle(ChatTheme.warning) }
                }
                if !workspace.remotes.profiles.isEmpty {
                    Section("Paired agents") {
                        ForEach(workspace.orderedProfiles) { profile in
                            let id = profile.id.uuidString
                            let pinned = workspace.favorites.contains(id)
                            Menu {
                                Button(pinned ? "Unpin agent" : "Pin agent", systemImage: pinned ? "pin.slash" : "pin") {
                                    workspace.toggleFavorite(id)
                                }
                                Button("Copy workspace ID", systemImage: "doc.on.doc") {
                                    UIPasteboard.general.string = id
                                }
                                Button("Forget remote", systemImage: "trash", role: .destructive) { forgetting = profile }
                            } label: {
                                WorkspaceRow(title: profile.name, subtitle: profile.kind.name,
                                             symbol: pinned ? "pin" : "server.rack")
                            }
                        }
                    }
                }
                if !workspace.roster.isEmpty && (workspace.remotes.profiles.isEmpty || workspace.showDemoAgents) {
                    Section {
                        ForEach(pins.wrappedValue, id: \.self) { id in
                            if let agent = workspace.roster.first(where: { $0.target.id == id }) {
                                pinRow(agent.target, pinned: true)
                            }
                        }
                        .onMove { pins.wrappedValue.move(fromOffsets: $0, toOffset: $1) }
                    } header: { Text("Pinned demos") }
                    let remaining = workspace.roster.filter { !pins.wrappedValue.contains($0.target.id) }
                    if !remaining.isEmpty {
                        Section("Available to pin") {
                            ForEach(remaining, id: \.target.id) { model in pinRow(model.target, pinned: false) }
                        }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Manage agents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $pairing) { PairRemoteScreen(store: workspace.remotes) }
            .confirmationDialog("Forget this remote?", isPresented: Binding(
                get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }
            ), titleVisibility: .visible, presenting: forgetting) { profile in
                Button("Forget", role: .destructive) {
                    do {
                        try workspace.remotes.forget(profile)
                        workspace.forgot(profile.id.uuidString)
                        issue = nil
                    } catch { issue = error.localizedDescription }
                    forgetting = nil
                }
            } message: { _ in
                Text("Riptide removes the connection and its token from this device. Chats on the host stay in place.")
            }
        }
    }

    private func pinRow(_ agent: AgentTarget, pinned: Bool) -> some View {
        HStack {
            Text(agent.name)
            Spacer()
            Button {
                if pinned { pins.wrappedValue.removeAll { $0 == agent.id } }
                else if pins.wrappedValue.count < 4 { pins.wrappedValue.append(agent.id) }
            } label: {
                Image(systemName: pinned ? "pin.slash" : "pin").frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .disabled(!pinned && pins.wrappedValue.count >= 4)
            .accessibilityLabel(pinned ? "Unpin \(agent.name)" : "Pin \(agent.name)")
            .accessibilityIdentifier("\(pinned ? "unpin" : "pin")-\(agent.id)")
        }
    }
}
