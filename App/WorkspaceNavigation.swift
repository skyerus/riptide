import RiptideCore
import SwiftUI

struct WorkspaceNavigation: View {
    @Bindable var workspace: WorkspaceState
    @Environment(\.scenePhase) private var scenePhase
    @State private var alerts = WorkspaceAlerts()

    var body: some View {
        NavigationStack(path: $workspace.path) {
            AgentRoster(roster: workspace.roster, localCodex: workspace.localCodex, remotes: workspace.remotes)
                .navigationDestination(for: WorkspaceRoute.self) { route in
                    WorkspaceDestination(route: route)
                        .id(route)
                }
        }
        .environment(workspace)
        .environment(alerts)
        .sheet(isPresented: $workspace.showingSwitcher, onDismiss: {
            if workspace.inboxRequested { workspace.inboxRequested = false; workspace.showingInbox = true }
            else if workspace.alertsRequested { workspace.alertsRequested = false; workspace.showingAlerts = true }
        }) { WorkspaceSwitcher().environment(workspace) }
        .sheet(isPresented: $workspace.showingInbox, onDismiss: {
            if workspace.alertsRequested { workspace.alertsRequested = false; workspace.showingAlerts = true }
        }) { AttentionInbox().environment(workspace).environment(alerts) }
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
                        workspace.showingInbox = true
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
        VStack(spacing: 0) {
            WorkspaceRail(selected: route.workspace)
            destination
        }
        .background(ChatTheme.background)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { WorkspaceSwitcherButton() }
        }
    }

    @ViewBuilder
    private var destination: some View {
        if let model = workspace.roster.first(where: { $0.target.id == route.workspace }) {
            ChatScreen(model: model, initialChatID: route.chat)
        } else if route.workspace == WorkspaceState.localID, let endpoint = workspace.localCodex {
            if let chat = route.chat {
                focusedCodex(endpoint, chat: chat)
            } else {
                CodexLiveScreen(endpoint: endpoint)
            }
        } else if let profile = workspace.profile(route.workspace), let bearer = workspace.remotes.bearer(for: profile) {
            if let endpoint = CodexLocalEndpoint(remote: profile, bearer: bearer) {
                if let chat = route.chat {
                    focusedCodex(endpoint, chat: chat)
                } else {
                    CodexChatsScreen(endpoint: endpoint, name: profile.name, selectionKey: route.workspace,
                                     workspaceID: route.workspace)
                }
            } else {
                WorkspaceACPDestination(profile: profile, bearer: bearer, chatID: route.chat)
            }
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
                Button("Open Inbox", systemImage: "tray") { workspace.showingInbox = true }
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
    let selected: String
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var canScroll = false

    var body: some View {
        HStack(spacing: 0) {
            agentStrip
            inboxShortcut
        }
        .background(ChatTheme.background)
        .sensoryFeedback(.selection, trigger: selected)
        .overlay(alignment: .bottom) { Rectangle().fill(ChatTheme.border).frame(height: 1).allowsHitTesting(false) }
    }

    private var agentStrip: some View {
        let urgent = Set(workspace.approvalIDs.map(\.chat.workspace))
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(workspace.railAgents(selected: selected)) { agent in
                        Button {
                            if agent.id != selected { workspace.open(agent.id) }
                        } label: {
                            Label(agent.name, systemImage: agent.symbol)
                                .font(.subheadline.weight(agent.id == selected ? .semibold : .medium))
                                .foregroundStyle(agent.id == selected ? ChatTheme.accent : ChatTheme.muted)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(agent.id == selected ? ChatTheme.selected : .clear, in: Capsule())
                                .overlay(alignment: .topTrailing) {
                                    if urgent.contains(agent.id) {
                                        Circle().fill(ChatTheme.warning).frame(width: 6, height: 6).padding(4)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(agent.id)
                        .accessibilityAddTraits(agent.id == selected ? .isSelected : [])
                        .accessibilityIdentifier("rail-\(agent.id)")
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.width > geometry.containerSize.width + 4
            } action: { _, overflow in canScroll = overflow }
            .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
                guard !canScroll, abs(value.translation.width) >= 48,
                      abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                workspace.step(from: selected, by: value.translation.width < 0 ? 1 : -1)
            })
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
            .onChange(of: selected) {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { proxy.scrollTo(selected, anchor: .center) }
            }
            .accessibilityLabel("Workspaces")
            .accessibilityAction(named: "Previous workspace") { workspace.step(from: selected, by: -1) }
            .accessibilityAction(named: "Next workspace") { workspace.step(from: selected, by: 1) }
        }
    }

    @ViewBuilder private var inboxShortcut: some View {
        let waiting = workspace.inboxRows.filter { $0.reason != .followUp }.count
        if waiting > 0 {
            Button { workspace.showingInbox = true } label: {
                Image(systemName: "tray")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ChatTheme.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .overlay(alignment: .topTrailing) {
                        Text(waiting > 99 ? "99+" : waiting.formatted())
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(ChatTheme.background)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(ChatTheme.accent, in: Capsule())
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                    }
            }
            .padding(.trailing, 14)
            .buttonStyle(.plain)
            .accessibilityLabel("Inbox")
            .accessibilityValue("\(waiting) waiting")
            .accessibilityIdentifier("rail-inbox")
        }
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
        if search.isEmpty { return Array(workspace.recent.prefix(4)) }
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
    let title: String
    let subtitle: String
    let symbol: String
    var color: Color = ChatTheme.accent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(ChatTheme.ink)
                if !subtitle.isEmpty { Text(subtitle).font(.footnote).foregroundStyle(ChatTheme.muted) }
            }
            Spacer(minLength: 4)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
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

private struct AttentionInbox: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(WorkspaceAlerts.self) private var alerts
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                let search = WorkspaceSearch(query)
                let names = Dictionary(uniqueKeysWithValues: workspace.agents.map { ($0.id, $0.name) })
                let entries = workspace.inboxRows.filter { entry in
                    search.score(title: entry.title,
                                 context: "\(names[entry.chat.workspace] ?? "") \(entry.reason.title)") != nil
                }
                if entries.isEmpty {
                    if search.isEmpty {
                        ContentUnavailableView("You’re caught up", systemImage: "tray",
                                               description: Text("Approvals, replies you missed, and chats you save for later appear here."))
                            .listRowBackground(Color.clear)
                    } else {
                        ContentUnavailableView.search(text: query).listRowBackground(Color.clear)
                    }
                }
                section("Needs you", items: entries.filter { $0.reason == .approval || $0.reason == .input })
                section("Replies", items: entries.filter { $0.reason == .reply })
                section("Saved for later", items: entries.filter { $0.reason == .followUp })
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(ChatTheme.background)
            .navigationTitle("Inbox")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search Inbox")
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
            .refreshable {
                _ = await workspace.pollCodex()
                if let entries = await alerts.relayInbox() { workspace.updateRelayInbox(entries) }
                else { workspace.expireRelayInbox() }
            }
        }
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("workspace-inbox")
    }

    @ViewBuilder
    private func section(_ title: String, items: [WorkspaceAttention]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    let name = workspace.agent(item.chat.workspace)?.name
                    let isMain = workspace.isMainChat(item.chat)
                    let title = isMain ? name ?? item.title : item.title
                    let subtitle = [isMain || name == title ? nil : name, item.reason.title].compactMap { $0 }.joined(separator: " · ")
                    Button { workspace.open(item.chat.workspace, chat: item.chat.chat) } label: {
                        WorkspaceRow(title: title, subtitle: subtitle,
                                     symbol: item.reason == .followUp ? "bookmark" : item.reason == .reply ? "bubble.left" : "bell.badge",
                                     color: item.reason == .approval || item.reason == .input ? ChatTheme.warning : ChatTheme.accent)
                    }
                    .accessibilityIdentifier("inbox-\(item.reason.rawValue)-\(item.chat.workspace)")
                    .listRowBackground(ChatTheme.surface)
                    .swipeActions {
                        if item.reason == .followUp || item.reason == .reply {
                            Button("Clear", systemImage: "checkmark") { workspace.clear(item.chat, reason: item.reason) }
                                .tint(ChatTheme.selected)
                        }
                    }
                }
            }
        }
    }
}
