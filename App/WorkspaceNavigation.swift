import RiptideCore
import SwiftUI

struct WorkspaceNavigation: View {
    @Bindable var workspace: WorkspaceState
    @Environment(\.scenePhase) private var scenePhase
    @State private var alerts = WorkspaceAlerts()
    @State private var sideChatsAgent: WorkspaceAgent?
    @State private var drawerSelection: WorkspaceRoute?
    @State private var switcherSelection: WorkspaceRoute?

    var body: some View {
        VStack(spacing: 0) {
            if let call = workspace.calls.active, workspace.calls.presentation == nil, !call.finished {
                VoiceCallBar(call: call, resume: workspace.calls.resume)
            }
            NavigationStack(path: $workspace.path) {
                WorkspaceSidebar()
                    .navigationDestination(for: WorkspaceRoute.self) { route in
                        WorkspaceDestination(route: route, showSideChats: { sideChatsAgent = $0 })
                            .id(route)
                    }
            }
        }
        .fullScreenCover(item: Binding(
            get: { workspace.calls.presentation }, set: { workspace.calls.presentation = $0 }
        )) { presentation in
            switch presentation {
            case .codex(let call):
                CodexVoiceScreen(call: call, agent: workspace.agent(call.workspaceID)) {
                    workspace.calls.presentation = nil
                }
            case .native(let call):
                AgentCallScreen(call: call, agent: workspace.agent(call.locator.workspace), context: nil,
                                accessibilityPrefix: "native-voice", minimize: { workspace.calls.presentation = nil }) {
                    call.approvals()
                }
            }
        }
        .environment(workspace)
        .environment(alerts)
        .onChange(of: nativeCallLoaded) {
            if nativeCallLoaded == false, case .native(let call) = workspace.calls.active {
                call.finish("Chat disconnected.")
            }
        }
        .sheet(isPresented: $workspace.showingSwitcher, onDismiss: {
            if let route = switcherSelection {
                switcherSelection = nil
                if let chat = route.chat { workspace.open(route.workspace, chat: chat) }
                else { workspace.openMainChat(route.workspace) }
            } else if let tab = workspace.sidebarRequested {
                workspace.sidebarRequested = nil
                workspace.showSidebar(tab)
            }
            else if workspace.alertsRequested { workspace.alertsRequested = false; workspace.showingAlerts = true }
        }) {
            WorkspaceSwitcher { route in
                switcherSelection = route
                workspace.showingSwitcher = false
            }
            .environment(workspace)
        }
        .sheet(item: $sideChatsAgent, onDismiss: {
            if let selection = drawerSelection, workspace.path.last?.workspace == selection.workspace {
                workspace.open(selection)
            }
            drawerSelection = nil
        }) { agent in
            ChatPicker(agent: agent) { route in
                drawerSelection = route
                sideChatsAgent = nil
            }
            .environment(workspace)
        }
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
                alerts.remotes = workspace.remotes
                workspace.notifyAttention = { [weak workspace, weak alerts] entry in
                    guard let workspace, let alerts else { return }
                    alerts.receive(entry, appIsActive: workspace.sceneIsActive)
                }
                alerts.preloadReply = { [weak workspace] in workspace?.preloadReply(from: $0) }
                alerts.openWorkspace = { notification in
                    if let notification, workspace.agent(notification.chat.workspace) != nil {
                        workspace.preloadReply(from: notification)
                        let chat = notification.chat
                        workspace.open(chat.workspace, chat: chat.chat)
                    } else {
                        workspace.showSidebar(.inbox)
                    }
                }
                alerts.activate()
            }
        }
        .onChange(of: workspace.remotes.profiles.map(\.id)) {
            if scenePhase == .active { alerts.activate() }
        }
        .task(id: scenePhase) {
            if scenePhase == .active { await workspace.preloadRecentMainChat() }
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

    private var nativeCallLoaded: Bool? {
        guard case .native(let call) = workspace.calls.active else { return nil }
        return call.model.isLoaded(call.chatID)
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
    let showSideChats: (WorkspaceAgent) -> Void
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            if route.hermesGroup == nil, !route.opensMainChat, route.chat != nil || route.startsNewChat,
               let agent = workspace.agent(route.workspace) {
                HStack {
                    Button("Main Chat", systemImage: "arrow.uturn.backward") { workspace.openMainChat(agent.id) }
                        .buttonStyle(ChatNavigationButtonStyle())
                        .accessibilityIdentifier("return-to-main-chat")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, ChatTheme.gutter)
            }
            destination
        }
        .background(ChatTheme.background)
    }

    private var showMainSideChats: (() -> Void)? {
        guard route.opensMainChat, let agent = workspace.agent(route.workspace) else { return nil }
        return { showSideChats(agent) }
    }

    @ViewBuilder
    private var destination: some View {
        if let id = route.hermesGroup {
            if let session = workspace.hermesGroupSession(roomID: id, workspaceID: route.workspace) {
                HermesGroupScreen(workspaceName: workspace.agent(route.workspace)?.name ?? "Hermes",
                                  privateFileTransfer: workspace.privateFileTransfer(for: route.workspace), session: session)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) { WorkspaceSwitcherButton() }
                    }
            } else {
                ContentUnavailableView("Group chat unavailable", systemImage: "lock",
                                       description: Text("Unlock this device or pair the remote again."))
            }
        } else if let model = workspace.roster.first(where: { $0.target.id == route.workspace }) {
            ChatScreen(model: model, initialChatID: route.chat, showSideChats: showMainSideChats)
        } else if let endpoint = workspace.codexEndpoint(for: route.workspace) {
            if route.opensMainChat {
                CodexMainChatScreen(endpoint: endpoint, workspaceID: route.workspace, showSideChats: showMainSideChats)
            } else if route.startsNewChat {
                CodexSavedChatScreen(endpoint: endpoint, initialChat: nil, workspaceID: route.workspace)
            } else if let chat = route.chat {
                focusedCodex(endpoint, chat: chat)
            } else if route.workspace == WorkspaceState.localID, let agent = workspace.agent(route.workspace) {
                CodexLiveScreen(endpoint: endpoint, showSavedChats: { showSideChats(agent) })
            }
        } else if let profile = workspace.profile(route.workspace), profile.kind != .codex,
                  let bearer = workspace.remotes.bearer(for: profile) {
            WorkspaceACPDestination(profile: profile, bearer: bearer, chatID: route.chat, showSideChats: showMainSideChats)
        } else {
            ContentUnavailableView("Workspace unavailable", systemImage: "lock",
                                   description: Text("Unlock this device or pair the remote again."))
        }
    }

    private func focusedCodex(_ endpoint: CodexLocalEndpoint, chat: String) -> some View {
        let locator = WorkspaceChatID(workspace: route.workspace, chat: chat)
        return CodexSavedChatScreen(endpoint: endpoint, initialChat: CodexChatSummary(id: chat, title: workspace.displayName(for: locator)),
                                   workspaceID: route.workspace)
    }
}

private struct WorkspaceACPDestination: View {
    let profile: RemoteProfile
    let bearer: String
    let chatID: String?
    let showSideChats: (() -> Void)?
    @Environment(WorkspaceState.self) private var workspace
    @State private var model: AgentChatModel?

    var body: some View {
        Group {
            if let model {
                ChatScreen(model: model, voiceRemote: profile, remoteStore: workspace.remotes, initialChatID: chatID,
                           showSideChats: showSideChats)
            } else {
                ChatHistorySkeleton()
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
                    Button("Back to \(previous.name)", systemImage: "arrow.uturn.backward") { workspace.openMainChat(previous.id) }
                }
                Button("Open Inbox", systemImage: "tray") { workspace.showSidebar(.inbox) }
                Button("Open Agents", systemImage: "person.crop.circle") { workspace.showSidebar(.agents) }
                Button("Open Group chats", systemImage: "person.2") { workspace.showSidebar(.groups) }
            }
    }
}

struct WorkspaceSearchButton: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        Button("Find an agent or chat", systemImage: "magnifyingglass") { workspace.showingSwitcher = true }
            .keyboardShortcut("k", modifiers: .command)
            .accessibilityIdentifier("workspace-search")
    }
}

struct WorkspaceChatHeading: View {
    let title: String
    let workspaceName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).lineLimit(1)
            Text(workspaceName).font(.caption).foregroundStyle(ChatTheme.muted).lineLimit(1)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(workspaceName)
        .accessibilityAddTraits(.isHeader)
    }
}

struct SideChatsButton: View {
    let action: () -> Void

    var body: some View {
        Button("Side chats", systemImage: "bubble.left.and.bubble.right", action: action)
            .accessibilityIdentifier("open-side-chats")
    }
}

private struct ChatNavigationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(ChatTheme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(ChatTheme.surface, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

struct WorkspaceTabBar: View {
    let selected: WorkspaceTab
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection

    var body: some View {
        ViewThatFits(in: .horizontal) {
            tabs(expand: true)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) { tabs(expand: false) }
                    .scrollIndicators(.hidden)
                    .fixedSize(horizontal: false, vertical: true)
                    .onAppear { proxy.scrollTo(selected, anchor: .center) }
                    .onChange(of: selected) { proxy.scrollTo(selected, anchor: .center) }
            }
        }
        .padding(4)
        .chatGlass(in: Capsule())
        .padding(.horizontal, ChatTheme.gutter)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .sensoryFeedback(.selection, trigger: selected)
    }

    private func tabs(expand: Bool) -> some View {
        let waiting = workspace.inboxRows.count
        return HStack(spacing: 3) {
            tab(.inbox, title: "Inbox", symbol: "tray", selectedSymbol: "tray.fill",
                identifier: "sidebar-inbox", expand: expand, waiting: waiting)
            tab(.agents, title: "Agents", symbol: "person.crop.circle", selectedSymbol: "person.crop.circle.fill",
                identifier: "sidebar-agents", expand: expand)
            tab(.groups, title: "Groups", symbol: "person.2", selectedSymbol: "person.2.fill",
                identifier: "sidebar-group-chats", expand: expand)
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: selected)
    }

    private func tab(
        _ target: WorkspaceTab, title: String, symbol: String, selectedSymbol: String,
        identifier: String, expand: Bool, waiting: Int? = nil
    ) -> some View {
        let isSelected = selected == target
        return Button {
            if !isSelected { workspace.showSidebar(target) }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: isSelected ? selectedSymbol : symbol)
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 28, height: 22)
                    .overlay(alignment: .trailing) {
                        if let waiting, waiting > 0 {
                            Text(waiting > 99 ? "99+" : waiting.formatted())
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .padding(.horizontal, 4)
                                .frame(minWidth: 16, minHeight: 16)
                                .foregroundStyle(ChatTheme.background)
                                .background(ChatTheme.sidebarAccent, in: Capsule())
                                .offset(x: 13, y: -6)
                        }
                    }
                    .accessibilityHidden(true)
                Text(title)
                    .font(.footnote.weight(.medium))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(isSelected ? ChatTheme.ink : ChatTheme.ink.opacity(0.76))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minWidth: 44, maxWidth: expand ? .infinity : nil, minHeight: 49)
            .background {
                if isSelected {
                    Capsule().fill(.black.opacity(0.54))
                        .matchedGeometryEffect(id: "selected-workspace-tab", in: selection)
                        .transition(.identity)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(waiting.map { $0 == 0 ? "All caught up" : "\($0) waiting" } ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
        .id(target)
    }
}

private struct WorkspaceSwitcher: View {
    let select: (WorkspaceRoute) -> Void
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
                        workspace.sidebarRequested = .inbox
                        dismiss()
                    } label: {
                        Label("Inbox", systemImage: "tray")
                    }
                    .accessibilityIdentifier("switcher-inbox")
                    Button {
                        workspace.sidebarRequested = .agents
                        dismiss()
                    } label: {
                        Label("Agents", systemImage: "person.crop.circle")
                    }
                    .accessibilityIdentifier("switcher-agents")
                    Button {
                        workspace.sidebarRequested = .groups
                        dismiss()
                    } label: {
                        Label("Group chats", systemImage: "person.2")
                    }
                    .accessibilityIdentifier("switcher-group-chats")
                }
                if parsed.isEmpty { liveSection(names: names) }
                if parsed.isEmpty && !matchingChats.isEmpty { chats(matchingChats, names: names, recent: true) }
                if !matchingAgents.isEmpty {
                    Section("Workspaces") {
                        ForEach(matchingAgents) { agent in
                            Button { select(.init(workspace: agent.id, opensMainChat: true)) } label: {
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
                Button { select(.init(workspace: chat.id.workspace, chat: chat.id.chat)) } label: {
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
                    Button { select(.init(workspace: visit.id.workspace, chat: visit.id.chat)) } label: {
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
