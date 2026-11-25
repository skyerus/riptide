import RiptideCore
import SwiftUI

struct WorkspaceNavigation: View {
    @Bindable var workspace: WorkspaceState
    @Environment(\.scenePhase) private var scenePhase
    @State private var alerts = WorkspaceAlerts()

    var body: some View {
        NavigationStack(path: $workspace.path) {
            WorkspaceSidebar()
                .navigationDestination(for: WorkspaceRoute.self) { route in
                    WorkspaceDestination(route: route)
                        .id(route)
                }
        }
        .environment(workspace)
        .environment(alerts)
        .sheet(isPresented: $workspace.showingSwitcher, onDismiss: {
            if workspace.inboxRequested { workspace.inboxRequested = false; workspace.showSidebar(.inbox) }
            else if workspace.alertsRequested { workspace.alertsRequested = false; workspace.showingAlerts = true }
        }) { WorkspaceSwitcher().environment(workspace) }
        .sheet(isPresented: $workspace.showingAlerts) { WorkspaceAlertSettings().environment(alerts) }
        .onChange(of: workspace.approvalIDs) {
            notify(workspace.newApprovals())
        }
        .onChange(of: workspace.acpCompletions) {
            notify(workspace.handleACPCompletions(workspace.acpCompletions))
        }
        .onChange(of: workspace.path.isEmpty) {
            if workspace.path.isEmpty, let chat = workspace.visibleChat { workspace.leave(chat) }
        }
        .onChange(of: scenePhase, initial: true) {
            workspace.setSceneActive(scenePhase == .active)
            if scenePhase == .active {
                workspace.notifyAttention = { [weak workspace, weak alerts] entry in
                    guard let workspace, let alerts else { return }
                    alerts.receive(entry, appIsActive: workspace.sceneIsActive)
                }
                alerts.openWorkspace = { chat in
                    if let chat, workspace.agent(chat.workspace) != nil {
                        workspace.open(chat.workspace, chat: chat.chat)
                    } else {
                        workspace.showSidebar(.inbox)
                    }
                }
                alerts.activate()
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                notify(await workspace.pollCodex())
                if let relayed = await alerts.relayInbox() { workspace.updateRelayInbox(relayed) }
                else { workspace.expireRelayInbox() }
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
            }
        }
    }

    private func notify(_ entries: [WorkspaceAttention]) {
        for entry in entries where workspace.agent(entry.chat.workspace)?.connector != "Demo" {
            if workspace.sceneIsActive && workspace.visibleChat == entry.chat { continue }
            alerts.receive(entry, appIsActive: workspace.sceneIsActive)
        }
    }
}

private struct WorkspaceDestination: View {
    let route: WorkspaceRoute
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        destination
            .background(ChatTheme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { WorkspaceSwitcherButton() }
            }
    }

    @ViewBuilder
    private var destination: some View {
        if let model = workspace.roster.first(where: { $0.target.id == route.workspace }) {
            ChatScreen(model: model, initialChatID: route.chat)
        } else if let endpoint = workspace.codexEndpoint(for: route.workspace) {
            if route.startsNewChat {
                CodexSavedChatScreen(endpoint: endpoint, initialChat: nil, workspaceID: route.workspace, includesSwitcher: false) { _ in }
            } else if let chat = route.chat {
                focusedCodex(endpoint, chat: chat)
            } else if route.workspace == WorkspaceState.localID {
                CodexLiveScreen(endpoint: endpoint)
            } else {
                CodexChatsScreen(endpoint: endpoint, name: workspace.agent(route.workspace)?.name ?? "Codex",
                                 selectionKey: route.workspace, workspaceID: route.workspace)
            }
        } else if let profile = workspace.profile(route.workspace), profile.kind != .codex,
                  let bearer = workspace.remotes.bearer(for: profile) {
            WorkspaceACPDestination(profile: profile, bearer: bearer, chatID: route.chat)
        } else {
            ContentUnavailableView("Workspace unavailable", systemImage: "lock",
                                   description: Text("Unlock this device or pair the remote again."))
        }
    }

    private func focusedCodex(_ endpoint: CodexLocalEndpoint, chat: String) -> some View {
        let locator = WorkspaceChatID(workspace: route.workspace, chat: chat)
        return CodexSavedChatScreen(endpoint: endpoint, initialChat: CodexChatSummary(id: chat, title: workspace.displayName(for: locator)),
                                   workspaceID: route.workspace, includesSwitcher: false) { _ in }
    }
}

private struct WorkspaceACPDestination: View {
    let profile: RemoteProfile
    let bearer: String
    let chatID: String?
    @Environment(WorkspaceState.self) private var workspace
    @State private var model: AgentChatModel?

    var body: some View {
        Group {
            if let model {
                ChatScreen(model: model, voiceRemote: profile, remoteStore: workspace.remotes, initialChatID: chatID)
            } else {
                ProgressView("Opening workspace…")
            }
        }
        .task { model = workspace.configuredModel(profile, bearer: bearer) }
    }
}

struct WorkspaceSwitcherButton: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        Button("Switch workspace", systemImage: "rectangle.grid.1x2") { workspace.showingSwitcher = true }
            .labelStyle(.iconOnly)
            .keyboardShortcut("k", modifiers: .command)
            .accessibilityIdentifier("workspace-switcher")
            .contextMenu {
                if let previous = workspace.previousWorkspace {
                    Button("Back to \(previous.name)", systemImage: "arrow.uturn.backward") { workspace.open(previous.id) }
                }
                Button("Open Inbox", systemImage: "tray") { workspace.showSidebar(.inbox) }
            }
    }
}

struct WorkspaceChatHeading: View {
    let title: String
    let workspaceName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(title).font(.headline).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ChatTheme.muted)
                    .accessibilityHidden(true)
            }
            Text(workspaceName).font(.caption).foregroundStyle(ChatTheme.muted).lineLimit(1)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

extension View {
    func workspaceFlickNavigation(_ workspaceID: String) -> some View {
        modifier(WorkspaceFlickNavigation(workspaceID: workspaceID))
    }
}

private struct WorkspaceFlickNavigation: ViewModifier {
    let workspaceID: String
    @Environment(WorkspaceState.self) private var workspace

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
                guard abs(value.translation.width) >= 48,
                      abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                workspace.step(from: workspaceID, by: value.translation.width < 0 ? 1 : -1)
            })
            .accessibilityAction(named: "Previous workspace") { workspace.step(from: workspaceID, by: -1) }
            .accessibilityAction(named: "Next workspace") { workspace.step(from: workspaceID, by: 1) }
    }
}

struct WorkspaceRail: View {
    let selected: WorkspaceTab
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let waiting = workspace.inboxRows.count
        let urgent = Set(workspace.approvalIDs.map(\.chat.workspace))
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    tab(.inbox, title: "Inbox", symbol: "tray", identifier: "sidebar-inbox",
                        value: waiting == 0 ? "All caught up" : "\(waiting) waiting") {
                        if waiting > 0 {
                            Text(waiting > 99 ? "99+" : waiting.formatted())
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(ChatTheme.sidebarAccent)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.leading, ChatTheme.gutter)
                    .id(WorkspaceTab.inbox)
                    ForEach(workspace.railAgents(selected: selected.agentID)) { agent in
                        tab(.agent(agent.id), title: agent.name, symbol: agent.symbol,
                            identifier: "sidebar-agent-\(agent.id)",
                            value: urgent.contains(agent.id) ? "Needs attention" : "") {
                            if urgent.contains(agent.id) {
                                Circle().fill(ChatTheme.attention).frame(width: 5, height: 5)
                                    .accessibilityHidden(true)
                            }
                        }
                        .id(WorkspaceTab.agent(agent.id))
                    }
                }
                .padding(.trailing, ChatTheme.gutter)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("sidebar-workspace-tabs")
            .onAppear { proxy.scrollTo(selected, anchor: selected == .inbox ? .leading : .center) }
            .onChange(of: selected) {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                    proxy.scrollTo(selected, anchor: selected == .inbox ? .leading : .center)
                }
            }
        }
        .padding(.bottom, 10)
        .background(ChatTheme.background)
        .sensoryFeedback(.selection, trigger: selected)
    }

    private func tab<Accessory: View>(
        _ target: WorkspaceTab, title: String, symbol: String, identifier: String, value: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        let isSelected = selected == target
        return Button {
            guard !isSelected else { return }
            workspace.showSidebar(target)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(isSelected ? ChatTheme.sidebarAccent : ChatTheme.muted)
                    .accessibilityHidden(true)
                Text(title).lineLimit(1)
                accessory()
            }
            .font(.subheadline.weight(isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? ChatTheme.ink : ChatTheme.muted)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .background(isSelected ? ChatTheme.raised : .clear, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

private struct WorkspaceSwitcher: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func agentMatches(_ search: WorkspaceSearch, in agents: [WorkspaceAgent]) -> [WorkspaceAgent] {
        if search.isEmpty { return agents }
        var matches: [(agent: WorkspaceAgent, score: Int)] = []
        for agent in agents {
            if let score = search.score(title: agent.name, context: agent.connector) {
                matches.append((agent, score))
            }
        }
        matches.sort { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.agent.name.localizedStandardCompare(right.agent.name) == .orderedAscending
        }
        return matches.map(\.agent)
    }
    private func chatMatches(_ search: WorkspaceSearch, names: [String: String]) -> [WorkspaceVisit] {
        if search.isEmpty { return Array(workspace.recent.lazy.filter { names[$0.id.workspace] != nil }.prefix(4)) }
        var matches: [(chat: WorkspaceVisit, score: Int, index: Int)] = []
        for (index, chat) in workspace.knownChats.enumerated() {
            if let score = search.score(title: chat.title, context: names[chat.id.workspace] ?? "") {
                matches.append((chat, score, index))
            }
        }
        matches.sort { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.index < right.index
        }
        return matches.prefix(30).map(\.chat)
    }

    var body: some View {
        let parsed = WorkspaceSearch(query)
        let agents = workspace.agents
        let names = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0.name) })
        let matchingAgents = agentMatches(parsed, in: agents)
        let matchingChats = chatMatches(parsed, names: names)
        NavigationStack {
            List {
                if query.isEmpty {
                    Button {
                        workspace.inboxRequested = true
                        dismiss()
                    } label: {
                        Label("Inbox", systemImage: "tray")
                    }
                    .accessibilityIdentifier("switcher-inbox")
                }
                if parsed.isEmpty { liveSection(names: names) }
                if parsed.isEmpty && !matchingChats.isEmpty { chats(matchingChats, names: names, recent: true) }
                if !matchingAgents.isEmpty {
                    Section("Workspaces") {
                        ForEach(matchingAgents) { agent in
                            Button { workspace.open(agent.id) } label: {
                                WorkspaceRow(title: agent.name, subtitle: agent.connector, symbol: agent.symbol)
                            }
                            .accessibilityIdentifier("switch-\(agent.id)")
                        }
                    }
                }
                if !parsed.isEmpty && !matchingChats.isEmpty { chats(matchingChats, names: names, recent: false) }
                if !parsed.isEmpty && workspace.indexingChats {
                    ProgressView("Finding chats…")
                }
                if !parsed.isEmpty && !workspace.indexingChats && matchingAgents.isEmpty && matchingChats.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(ChatTheme.background)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find an agent or chat")
            .task(id: query.count >= 2) {
                if query.count >= 2 { await workspace.loadSearchCatalog() }
            }
            .navigationTitle("Switch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Notification settings", systemImage: "bell") {
                        workspace.alertsRequested = true
                        dismiss()
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("inbox-notifications")
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func chats(_ visits: [WorkspaceVisit], names: [String: String], recent: Bool) -> some View {
        Section(recent ? "Recent chats" : "Chats") {
            ForEach(visits) { chat in
                Button { workspace.open(chat.id.workspace, chat: chat.id.chat) } label: {
                    WorkspaceRow(title: chat.title, subtitle: names[chat.id.workspace] ?? "", symbol: "bubble.left")
                }
                .accessibilityIdentifier("switch-chat-\(chat.id.workspace)-\(chat.id.chat)")
            }
        }
    }

    @ViewBuilder
    private func liveSection(names: [String: String]) -> some View {
        let live = workspace.liveChats
        let urgent = Set(workspace.approvalIDs.map(\.chat))
        if !live.isEmpty {
            Section("Live now") {
                ForEach(live) { visit in
                    let needsYou = urgent.contains(visit.id)
                    Button { workspace.open(visit.id.workspace, chat: visit.id.chat) } label: {
                        WorkspaceRow(title: visit.title,
                                     subtitle: "\(names[visit.id.workspace] ?? "") · \(needsYou ? "Needs you" : "Working")",
                                     symbol: needsYou ? "bell.badge" : "waveform",
                                     color: needsYou ? ChatTheme.warning : ChatTheme.accent)
                    }
                    .accessibilityIdentifier("live-\(visit.id.workspace)-\(visit.id.chat)")
                }
            }
        }
    }
}

struct WorkspaceRow: View {
    private static let iconWidth: CGFloat = 24
    private static let spacing: CGFloat = 10
    static let textInset = iconWidth + spacing

    let title: String
    let subtitle: String
    let symbol: String
    var color: Color = ChatTheme.accent
    var featured = false

    var body: some View {
        HStack(spacing: Self.spacing) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(color)
                .frame(minWidth: Self.iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(featured ? .semibold : .medium))
                    .foregroundStyle(ChatTheme.ink)
                if !subtitle.isEmpty { Text(subtitle).font(.footnote).foregroundStyle(ChatTheme.muted) }
            }
            Spacer(minLength: 8)
            if featured {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ChatTheme.muted)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, featured ? 14 : 0)
        .frame(minHeight: featured ? 58 : 44)
        .padding(.vertical, featured ? 4 : 0)
        .background(featured ? ChatTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
    }
}

struct InboxItemLabel: View {
    let item: WorkspaceAttention
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        let name = workspace.agent(item.chat.workspace)?.name
        let isMain = workspace.isMainChat(item.chat)
        let title = isMain ? name ?? item.title : item.title
        let subtitle = [isMain || name == title ? nil : name, item.reason.title].compactMap { $0 }.joined(separator: " · ")
        let appearance: (symbol: String, color: Color) = switch item.reason {
        case .approval: ("lock.shield.fill", ChatTheme.attention)
        case .input: ("questionmark.bubble.fill", ChatTheme.attention)
        case .reply: ("bubble.left.fill", ChatTheme.sidebarAccent)
        case .followUp: ("bookmark", ChatTheme.muted)
        }
        WorkspaceRow(title: title, subtitle: subtitle,
                     symbol: appearance.symbol, color: appearance.color)
    }
}

struct FollowUpButton: View {
    let chat: WorkspaceChatID
    let title: String
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        let saved = workspace.isFollowing(chat)
        Button(saved ? "Remove from Inbox" : "Save to Inbox", systemImage: saved ? "bookmark.slash" : "bookmark") {
            workspace.toggleFollowUp(chat, title: title)
        }
        .accessibilityIdentifier("follow-up-chat")
    }
}

struct WorkspaceInboxList: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(WorkspaceAlerts.self) private var alerts
    @State private var query = ""

    var body: some View {
        let items = workspace.inboxRows
        let search = WorkspaceSearch(query)
        let names = Dictionary(uniqueKeysWithValues: workspace.agents.map { ($0.id, $0.name) })
        let entries = items.filter { entry in
            search.score(title: entry.title, context: "\(names[entry.chat.workspace] ?? "") \(entry.reason.title)") != nil
        }
        List {
            if items.count >= 6 || !query.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(ChatTheme.muted)
                        .accessibilityHidden(true)
                    TextField("Search Inbox", text: $query, prompt: Text("Search Inbox").foregroundStyle(ChatTheme.muted))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("inbox-search")
                }
                .font(.subheadline)
                .foregroundStyle(ChatTheme.ink)
                .padding(.horizontal, 12)
                .frame(minHeight: 40)
                .background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 11))
                .sidebarRowStyle()
            }
            if search.isEmpty,
               let chat = workspace.recent.first(where: { names[$0.id.workspace] != nil }),
               let name = names[chat.id.workspace] {
                Section {
                    Button { workspace.open(chat.id.workspace, chat: chat.id.chat) } label: {
                        WorkspaceRow(title: chat.title, subtitle: name, symbol: "bubble.left.fill",
                                     color: ChatTheme.sidebarAccent, featured: true)
                            .lineLimit(2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("inbox-last-opened-chat")
                    .sidebarRowStyle()
                } header: {
                    SidebarSectionTitle("Last opened chat")
                        .sidebarHeaderStyle()
                }
                .listSectionSeparator(.hidden)
            }
            if entries.isEmpty {
                if search.isEmpty {
                    WorkspaceRow(title: "You’re caught up", subtitle: "New replies and requests will appear here.",
                                 symbol: "checkmark.circle", color: ChatTheme.muted)
                        .padding(.vertical, 8)
                        .sidebarRowStyle()
                } else {
                    ContentUnavailableView.search(text: query)
                        .sidebarRowStyle()
                }
            }
            section("Needs you", items: entries.filter { $0.reason == .approval || $0.reason == .input })
            section("Replies", items: entries.filter { $0.reason == .reply })
            section("Saved for later", items: entries.filter { $0.reason == .followUp })
        }
        .listStyle(.plain)
        .listSectionSpacing(12)
        .scrollContentBackground(.hidden)
        .background(ChatTheme.background)
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            _ = await workspace.pollCodex()
            if let entries = await alerts.relayInbox() { workspace.updateRelayInbox(entries) }
            else { workspace.expireRelayInbox() }
        }
    }

    @ViewBuilder
    private func section(_ title: String, items: [WorkspaceAttention]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    Button { workspace.open(item.chat.workspace, chat: item.chat.chat) } label: {
                        InboxItemLabel(item: item)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("inbox-\(item.reason.rawValue)-\(item.chat.workspace)")
                    .sidebarRowStyle(divider: item.id != items.last?.id)
                    .swipeActions {
                        if item.reason == .followUp || item.reason == .reply {
                            Button("Clear", systemImage: "checkmark") { workspace.clear(item.chat, reason: item.reason) }
                                .tint(ChatTheme.selected)
                        }
                    }
                }
            } header: {
                SidebarSectionTitle(title)
                    .sidebarHeaderStyle()
            }
            .listSectionSeparator(.hidden)
        }
    }
}
