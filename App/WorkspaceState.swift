import Observation
import RiptideCore
import SwiftUI

enum WorkspaceTab: Hashable {
    case inbox
    case agent(String)

    var agentID: String? {
        if case .agent(let id) = self { return id }
        return nil
    }
}

struct WorkspaceRoute: Hashable {
    let workspace: String
    var chat: String?
    var startsNewChat = false
}

struct WorkspaceAgent: Identifiable, Equatable {
    let id: String
    let name: String
    let connector: String
    let symbol: String
}

struct WorkspaceVisit: Identifiable, Codable, Equatable {
    let id: WorkspaceChatID
    let title: String
}

@MainActor @Observable
final class WorkspaceDrafts {
    private var values: [WorkspaceChatID: String] = [:]

    subscript(id: WorkspaceChatID) -> String {
        get { values[id] ?? "" }
        set { values[id] = newValue.isEmpty ? nil : newValue }
    }

    func remove(workspace: String) { values = values.filter { $0.key.workspace != workspace } }
}

@MainActor @Observable
final class WorkspaceState {
    static let localID = "local-codex"
    let roster: [AgentChatModel]
    let localCodex: CodexLocalEndpoint?
    let remotes: RemoteStore
    let drafts = WorkspaceDrafts()
    private let defaults: UserDefaults
    var path: [WorkspaceRoute] = []
    private(set) var sidebarTab: WorkspaceTab = .inbox
    private(set) var inboxReset = 0
    var showingSwitcher = false
    var showingAlerts = false
    var inboxRequested = false
    var alertsRequested = false
    private(set) var visibleChat: WorkspaceChatID?
    private(set) var recent: [WorkspaceVisit]
    private(set) var favorites: [String]
    private(set) var demoPins: [String]
    private(set) var showDemoAgents: Bool
    private var savedAttention: [WorkspaceAttention]
    private var remoteModels: [String: AgentChatModel] = [:]
    private var codexChats: [String: [CodexChatSummary]] = [:]
    private var codexSearchCatalog: [String: [CodexChatSummary]] = [:]
    private var lastCatalogRefresh: Date?
    private(set) var indexingChats = false
    private struct LiveCodexAttention {
        let reason: AttentionReason?
        let date: Date
    }
    private var liveCodexAttention: [WorkspaceChatID: LiveCodexAttention] = [:]
    private var runningCodexChats = Set<WorkspaceChatID>()
    private var clearedRelayEvents = Set<String>()
    @ObservationIgnored private var codexSessions: [WorkspaceChatID: CodexWorkspaceSession] = [:]
    @ObservationIgnored private var codexRecency: [WorkspaceChatID] = []
    @ObservationIgnored private var readingOffsets: [WorkspaceChatID: CGFloat] = [:]
    @ObservationIgnored var notifyAttention: ((WorkspaceAttention) -> Void)?
    private var relayedInbox: [RelayedAttention] = []
    private var readRelayReplies: [String]
    private var seenACPCompletions: [WorkspaceChatID: Date] = [:]
    private var reportedCodexCompletion: [WorkspaceChatID: Date] = [:]
    @ObservationIgnored private var attemptedMainChatPreload = false
    private(set) var sceneIsActive = true
    private(set) var observedApprovals = Set<WorkspaceAttention.ID>()

    init(roster: [AgentChatModel], localCodex: CodexLocalEndpoint?, remotes: RemoteStore, defaults: UserDefaults) {
        self.roster = roster
        self.localCodex = localCodex
        self.remotes = remotes
        self.defaults = defaults
        recent = (try? JSONDecoder().decode([WorkspaceVisit].self,
                                          from: defaults.data(forKey: "workspace.recent") ?? Data())) ?? []
        savedAttention = (try? JSONDecoder().decode([WorkspaceAttention].self,
                                                   from: defaults.data(forKey: "workspace.attention") ?? Data())) ?? []
        readRelayReplies = defaults.stringArray(forKey: "workspace.relay-read") ?? []
        favorites = defaults.stringArray(forKey: "workspace.favorites") ?? []
        let availableDemos = Set(roster.map(\.target.id))
        let storedPins = (try? JSONDecoder().decode([String].self, from: defaults.data(forKey: "roster.pinned") ?? Data()))
            ?? Array(roster.prefix(4).map(\.target.id))
        demoPins = storedPins.filter(availableDemos.contains)
        showDemoAgents = defaults.bool(forKey: "roster.show-demos")
    }

    var needsFirstAgent: Bool { remotes.profiles.isEmpty && localCodex == nil && roster.isEmpty }

    var agents: [WorkspaceAgent] {
        let paired = orderedProfiles.map {
            WorkspaceAgent(id: $0.id.uuidString, name: $0.name, connector: $0.kind.name, symbol: Self.icon($0.kind))
        }
        let desktop = localCodex == nil ? [] : [
            WorkspaceAgent(id: Self.localID, name: "Codex on this Mac", connector: "Codex", symbol: "desktopcomputer")
        ]
        return paired + desktop + roster.map {
            WorkspaceAgent(id: $0.target.id, name: $0.target.name, connector: "Demo",
                           symbol: $0.target.id == "hermes" ? "waveform" : "terminal")
        }
    }

    var orderedProfiles: [RemoteProfile] {
        let byID = Dictionary(uniqueKeysWithValues: remotes.profiles.map { ($0.id.uuidString, $0) })
        let first = favorites.compactMap { byID[$0] }
        return first + remotes.profiles.filter { !favorites.contains($0.id.uuidString) }
    }

    var knownChats: [WorkspaceVisit] {
        var seen = Set<WorkspaceChatID>()
        let acp = models.flatMap { model in
            model.sessions.map {
                WorkspaceVisit(id: .init(workspace: model.target.id, chat: $0.id),
                               title: $0.id == model.target.mainSessionID ? "Main Chat" : $0.title)
            }
        }
        let codex = codexChats.flatMap { id, chats in
            chats.map { WorkspaceVisit(id: .init(workspace: id, chat: $0.id), title: $0.title) }
        }
        let indexed = codexSearchCatalog.flatMap { id, chats in
            chats.map { WorkspaceVisit(id: .init(workspace: id, chat: $0.id), title: $0.title) }
        }
        let available = Set(agents.map(\.id))
        return (recent + acp + codex + indexed).filter { visit in
            available.contains(visit.id.workspace) && seen.insert(visit.id).inserted
        }
    }

    var previousWorkspace: WorkspaceAgent? {
        guard let current = path.last?.workspace else { return nil }
        return recent.lazy.filter { $0.id.workspace != current }.compactMap { self.agent($0.id.workspace) }.first
    }

    var inbox: [WorkspaceAttention] {
        var unique: [WorkspaceAttention.ID: WorkspaceAttention] = [:]
        let now = Date.distantPast
        for entry in savedAttention where agent(entry.chat.workspace) != nil { unique[entry.id] = entry }
        for entry in relayedInbox where agent(entry.workspace) != nil &&
            !readRelayReplies.contains(entry.receipt) && !clearedRelayEvents.contains(entry.receipt) {
            let row = WorkspaceAttention(chat: entry.locator, title: displayName(for: entry.locator),
                                         reason: entry.reason, date: Date(timeIntervalSince1970: entry.observedAt))
            if unique[row.id] == nil { unique[row.id] = row }
        }
        for model in models {
            for (chat, date) in model.pendingApprovalSince {
                let entry = WorkspaceAttention(chat: .init(workspace: model.target.id, chat: chat),
                                               title: model.title(for: chat), reason: .approval, date: date)
                unique[entry.id] = entry
            }
        }
        for (id, chats) in codexChats where agent(id) != nil {
            for chat in chats {
                let key = WorkspaceChatID(workspace: id, chat: chat.id)
                if liveCodexAttention[key] != nil { continue }
                let reason: AttentionReason? = chat.status == .approval ? .approval : chat.status == .input ? .input : nil
                guard let reason else { continue }
                let entry = WorkspaceAttention(chat: key, title: chat.title, reason: reason, date: chat.updatedAt ?? now)
                unique[entry.id] = entry
            }
        }
        for (chat, state) in liveCodexAttention where agent(chat.workspace) != nil {
            guard let reason = state.reason else { continue }
            let key = WorkspaceAttention.ID(chat: chat, reason: reason)
            unique[key] = .init(chat: chat, title: displayName(for: chat), reason: reason, date: state.date)
        }
        return WorkspaceAttention.prioritized(Array(unique.values))
    }

    var approvalIDs: Set<WorkspaceAttention.ID> {
        Set(inbox.lazy.filter { $0.reason == .approval || $0.reason == .input }.map(\.id))
    }

    var inboxRows: [WorkspaceAttention] { WorkspaceAttention.onePerChat(inbox) }

    var liveChats: [WorkspaceVisit] {
        var locations = runningCodexChats
        for model in models {
            for chat in model.workingChats { locations.insert(.init(workspace: model.target.id, chat: chat)) }
        }
        for (workspaceID, chats) in codexChats {
            for chat in chats where chat.status == .active || chat.status == .approval || chat.status == .input {
                locations.insert(.init(workspace: workspaceID, chat: chat.id))
            }
        }
        let urgent = Set(approvalIDs.map(\.chat))
        locations.formUnion(urgent)
        let names = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0.name) })
        var ordered = Array(locations.filter { names[$0.workspace] != nil && $0 != visibleChat })
        ordered.sort { left, right in
            if urgent.contains(left) != urgent.contains(right) { return urgent.contains(left) }
            let leftName = names[left.workspace] ?? ""
            let rightName = names[right.workspace] ?? ""
            if leftName != rightName { return leftName.localizedStandardCompare(rightName) == .orderedAscending }
            return left.chat < right.chat
        }
        return ordered.map { WorkspaceVisit(id: $0, title: displayName(for: $0)) }
    }

    var acpCompletions: [WorkspaceChatID: AgentChatModel.CompletedReply] {
        var result: [WorkspaceChatID: AgentChatModel.CompletedReply] = [:]
        for model in models {
            for (chat, reply) in model.completedReplies {
                result[.init(workspace: model.target.id, chat: chat)] = reply
            }
        }
        return result
    }

    private var models: [AgentChatModel] { roster + Array(remoteModels.values) }

    func agent(_ id: String) -> WorkspaceAgent? { agents.first { $0.id == id } }
    func profile(_ id: String) -> RemoteProfile? { remotes.profiles.first { $0.id.uuidString == id } }

    func isMainChat(_ chat: WorkspaceChatID) -> Bool {
        mainChatID(for: chat.workspace) == chat.chat
    }

    func mainChatID(for workspaceID: String) -> String? {
        roster.first { $0.target.id == workspaceID }?.target.mainSessionID ?? profile(workspaceID)?.mainSessionID
    }

    func sidebarChats(for workspaceID: String) -> [WorkspaceVisit] {
        knownChats.filter { $0.id.workspace == workspaceID && !isMainChat($0.id) }
    }

    func codexEndpoint(for workspaceID: String) -> CodexLocalEndpoint? {
        if workspaceID == Self.localID { return localCodex }
        guard let profile = profile(workspaceID), let bearer = remotes.bearer(for: profile) else { return nil }
        return CodexLocalEndpoint(remote: profile, bearer: bearer)
    }

    func sidebarACPModel(for workspaceID: String) -> AgentChatModel? {
        if let demo = roster.first(where: { $0.target.id == workspaceID }) { return demo }
        guard let profile = profile(workspaceID), let bearer = remotes.bearer(for: profile) else { return nil }
        return configuredModel(profile, bearer: bearer)
    }

    func preloadRecentMainChat() async {
        guard !attemptedMainChatPreload, !Task.isCancelled else { return }
        attemptedMainChatPreload = true
        guard path.isEmpty, let chat = recent.first?.id,
              mainChatID(for: chat.workspace) == chat.chat,
              let model = sidebarACPModel(for: chat.workspace) else { return }
        await model.preloadMain()
    }

    func rememberCodexCatalog(_ chats: [CodexChatSummary], workspaceID: String) {
        guard agent(workspaceID) != nil else { return }
        codexSearchCatalog[workspaceID] = chats
    }

    func displayName(for locator: WorkspaceChatID) -> String {
        recent.first { $0.id == locator }?.title ??
            codexChats[locator.workspace]?.first { $0.id == locator.chat }?.title ??
            codexSearchCatalog[locator.workspace]?.first { $0.id == locator.chat }?.title ??
            models.first { $0.target.id == locator.workspace }?.title(for: locator.chat) ??
            agent(locator.workspace)?.name ?? "Saved chat"
    }

    func updateRelayInbox(_ entries: [RelayedAttention]) {
        relayedInbox = entries
        clearedRelayEvents.formIntersection(entries.map(\.receipt))
        if sceneIsActive, let visibleChat { acknowledgeRelayReply(visibleChat) }
    }

    func expireRelayInbox(now: Date = .now) {
        relayedInbox.removeAll { now.timeIntervalSince1970 - $0.observedAt > 3_600 }
    }

    func configuredModel(_ profile: RemoteProfile, bearer: String) -> AgentChatModel? {
        let id = profile.id.uuidString
        if let existing = remoteModels[id] { return existing }
        guard let main = profile.mainSessionID else { return nil }
        let target = AgentTarget(id: id, name: profile.name, mainSessionID: main, cwd: profile.workspace)
        let model = AgentChatModel(target: target, connect: {
            profile.makeACPClient(credential: bearer) ?? ACPClient(transport: UnavailableWorkspaceTransport())
        })
        remoteModels[id] = model
        return model
    }

    func open(_ workspaceID: String, chat: String? = nil, resume: Bool = true) {
        guard agent(workspaceID) != nil else { return }
        let cachedChat = resume ? recent.first { $0.id.workspace == workspaceID }?.id.chat : nil
        push(WorkspaceRoute(workspace: workspaceID, chat: chat ?? cachedChat))
    }

    func startCodexChat(_ workspaceID: String) {
        guard codexEndpoint(for: workspaceID) != nil else { return }
        push(WorkspaceRoute(workspace: workspaceID, chat: nil, startsNewChat: true))
    }

    private func push(_ route: WorkspaceRoute) {
        showingSwitcher = false
        if path != [route] {
            visibleChat = nil
            path = [route]
        }
    }

    func showSidebar(_ tab: WorkspaceTab) {
        sidebarTab = tab
        if tab == .inbox { inboxReset += 1 }
        visibleChat = nil
        showingSwitcher = false
        if !path.isEmpty { path = [] }
    }

    func step(from workspaceID: String, by direction: Int) {
        let list = railAgents(selected: workspaceID)
        guard list.count > 1, let index = list.firstIndex(where: { $0.id == workspaceID }) else { return }
        open(list[(index + direction + list.count) % list.count].id)
    }

    func railAgents(selected: String?) -> [WorkspaceAgent] {
        let all = agents
        let paired = all.filter { $0.connector != "Demo" }
        let demos = all.filter { $0.connector == "Demo" }
        guard remotes.profiles.isEmpty || showDemoAgents else {
            return paired + demos.filter { $0.id == selected }
        }
        let byID = Dictionary(uniqueKeysWithValues: demos.map { ($0.id, $0) })
        return paired + demoPins.compactMap { byID[$0] } + demos.filter { !demoPins.contains($0.id) }
    }

    func setDemoPins(_ pins: [String]) {
        demoPins = pins
        if let data = try? JSONEncoder().encode(pins) { defaults.set(data, forKey: "roster.pinned") }
    }

    func setShowDemoAgents(_ value: Bool) {
        showDemoAgents = value
        defaults.set(value, forKey: "roster.show-demos")
        if !value, !remotes.profiles.isEmpty, let selected = sidebarTab.agentID,
           roster.contains(where: { $0.target.id == selected }) { sidebarTab = .inbox }
    }

    func visit(_ chat: WorkspaceChatID, title: String) {
        guard path.last?.workspace == chat.workspace else { return }
        visibleChat = chat
        let title = String(title.prefix(180))
        let entry = WorkspaceVisit(id: chat, title: title)
        if recent.first != entry {
            recent.removeAll { $0.id == chat }
            recent.insert(entry, at: 0)
            recent = Array(recent.prefix(40))
            persistRecent()
        }
        clear(chat, reason: .reply)
    }

    func leave(_ chat: WorkspaceChatID) {
        if visibleChat == chat { visibleChat = nil }
    }

    func readingOffset(for chat: WorkspaceChatID) -> CGFloat? { readingOffsets[chat] }

    func rememberReadingOffset(_ offset: CGFloat?, for chat: WorkspaceChatID) {
        readingOffsets[chat] = offset
    }

    func setSceneActive(_ active: Bool) { sceneIsActive = active }

    func isFollowing(_ chat: WorkspaceChatID) -> Bool {
        savedAttention.contains { $0.chat == chat && $0.reason == .followUp }
    }

    func toggleFollowUp(_ chat: WorkspaceChatID, title: String) {
        if isFollowing(chat) { clear(chat, reason: .followUp) }
        else { store(.init(chat: chat, title: String(title.prefix(180)), reason: .followUp)) }
    }

    func clear(_ chat: WorkspaceChatID, reason: AttentionReason) {
        if reason == .reply { acknowledgeRelayReply(chat) }
        let original = savedAttention.count
        savedAttention.removeAll { $0.chat == chat && $0.reason == reason }
        if savedAttention.count != original { persistAttention() }
    }

    func forgot(_ workspaceID: String) {
        if sidebarTab == .agent(workspaceID) { sidebarTab = .inbox }
        for key in codexRecency.filter({ $0.workspace == workspaceID }) {
            codexSessions.removeValue(forKey: key)?.detach()
        }
        codexRecency.removeAll { $0.workspace == workspaceID }
        remoteModels.removeValue(forKey: workspaceID)
        codexChats.removeValue(forKey: workspaceID)
        codexSearchCatalog.removeValue(forKey: workspaceID)
        lastCatalogRefresh = nil
        liveCodexAttention = liveCodexAttention.filter { $0.key.workspace != workspaceID }
        runningCodexChats = runningCodexChats.filter { $0.workspace != workspaceID }
        seenACPCompletions = seenACPCompletions.filter { $0.key.workspace != workspaceID }
        reportedCodexCompletion = reportedCodexCompletion.filter { $0.key.workspace != workspaceID }
        recent.removeAll { $0.id.workspace == workspaceID }
        savedAttention.removeAll { $0.chat.workspace == workspaceID }
        relayedInbox.removeAll { $0.workspace == workspaceID }
        drafts.remove(workspace: workspaceID)
        readingOffsets = readingOffsets.filter { $0.key.workspace != workspaceID }
        if favorites.contains(workspaceID) { toggleFavorite(workspaceID) }
        persistRecent()
        persistAttention()
    }

    func loadSearchCatalog() async {
        guard !indexingChats, lastCatalogRefresh.map({ Date().timeIntervalSince($0) >= 45 }) ?? true else { return }
        indexingChats = true
        defer { indexingChats = false }
        var acp = roster
        var codex: [(String, CodexLocalEndpoint)] = []
        if let localCodex { codex.append((Self.localID, localCodex)) }
        for profile in remotes.profiles {
            guard let bearer = remotes.bearer(for: profile) else { continue }
            if let endpoint = CodexLocalEndpoint(remote: profile, bearer: bearer) {
                codex.append((profile.id.uuidString, endpoint))
            } else if let model = configuredModel(profile, bearer: bearer) {
                acp.append(model)
            }
        }
        for offset in stride(from: 0, to: acp.count, by: 4) {
            guard !Task.isCancelled else { return }
            await withTaskGroup(of: Void.self) { group in
                for model in acp.dropFirst(offset).prefix(4) {
                    group.addTask { await model.refreshSessions(maximumPages: 4) }
                }
            }
        }
        for offset in stride(from: 0, to: codex.count, by: 4) {
            guard !Task.isCancelled else { return }
            await withTaskGroup(of: (String, [CodexChatSummary]?).self) { group in
                for (id, endpoint) in codex.dropFirst(offset).prefix(4) {
                    group.addTask {
                        let client = endpoint.makeClient()
                        let rows = try? await client.listSavedChats(maximumPages: 2)
                        await client.close()
                        return (id, rows)
                    }
                }
                for await (id, rows) in group where !Task.isCancelled && agent(id) != nil {
                    if let rows { codexSearchCatalog[id] = rows }
                }
            }
        }
        if !Task.isCancelled { lastCatalogRefresh = .now }
    }

    func toggleFavorite(_ workspaceID: String) {
        if favorites.contains(workspaceID) { favorites.removeAll { $0 == workspaceID } }
        else if profile(workspaceID) != nil { favorites.insert(workspaceID, at: 0) }
        defaults.set(favorites, forKey: "workspace.favorites")
    }

    func setCodexAttention(_ reason: AttentionReason?, chat: WorkspaceChatID, connected: Bool) {
        if !connected {
            liveCodexAttention[chat] = nil
        } else if liveCodexAttention[chat] == nil || liveCodexAttention[chat]?.reason != reason {
            guard reason != nil || liveCodexAttention[chat] != nil else { return }
            let old = liveCodexAttention[chat]?.reason
            liveCodexAttention[chat] = LiveCodexAttention(reason: reason, date: .now)
            if let old, old != reason {
                let cleared = relayedInbox.filter { $0.locator == chat && $0.reason == old }
                clearedRelayEvents.formUnion(cleared.map(\.receipt))
            }
        }
    }

    func setCodexRunning(_ running: Bool, chat: WorkspaceChatID) {
        if running { runningCodexChats.insert(chat) }
        else { runningCodexChats.remove(chat) }
    }

    func codexSession(endpoint: CodexLocalEndpoint, initialChat: CodexChatSummary?, workspaceID: String) -> CodexWorkspaceSession {
        if let initialChat, let existing = codexSessions[.init(workspace: workspaceID, chat: initialChat.id)] {
            retain(existing)
            return existing
        }
        let session = CodexWorkspaceSession(endpoint: endpoint, chat: initialChat, workspaceID: workspaceID, workspace: self)
        retain(session)
        return session
    }

    func retain(_ session: CodexWorkspaceSession) {
        guard let key = session.locator else { return }
        codexSessions[key] = session
        codexRecency.removeAll { $0 == key }
        codexRecency.insert(key, at: 0)
        pruneCodexSessions(except: key)
    }

    func pruneCodexSessions(except keep: WorkspaceChatID? = nil) {
        let idle = codexRecency.filter {
            $0 != visibleChat && $0 != keep && codexSessions[$0]?.needsConnection == false
        }
        for key in idle.dropFirst(4) {
            codexSessions.removeValue(forKey: key)?.detach()
            codexRecency.removeAll { $0 == key }
        }
    }

    func receivedCodexReply(_ chat: WorkspaceChatID, title: String, reply: String) {
        if let entry = codexCompleted(chat, title: title, reply: reply) { notifyAttention?(entry) }
    }

    func handleACPCompletions(_ completions: [WorkspaceChatID: AgentChatModel.CompletedReply]) -> [WorkspaceAttention] {
        var changed: [WorkspaceAttention] = []
        for (chat, reply) in completions where seenACPCompletions[chat] != reply.date {
            seenACPCompletions[chat] = reply.date
            if let model = models.first(where: { $0.target.id == chat.workspace }),
               let entry = recordReply(chat, title: model.title(for: chat.chat), date: reply.date, reply: reply.preview) {
                changed.append(entry)
            }
        }
        return changed
    }

    func newApprovals() -> [WorkspaceAttention] {
        let snapshot = approvalIDs
        let added = snapshot.subtracting(observedApprovals)
        observedApprovals = snapshot
        return inbox.filter { added.contains($0.id) }
    }

    private func codexCompleted(_ chat: WorkspaceChatID, title: String, reply: String) -> WorkspaceAttention? {
        reportedCodexCompletion[chat] = .now
        return recordReply(chat, title: title, date: .now, reply: reply)
    }

    func updateCodexChats(_ chats: [CodexChatSummary], workspaceID: String,
                          verifiedReplies: [String: String] = [:]) -> [WorkspaceAttention] {
        guard agent(workspaceID) != nil else { return [] }
        let previous = Dictionary(uniqueKeysWithValues: (codexChats[workspaceID] ?? []).map { ($0.id, $0.status) })
        codexChats[workspaceID] = chats
        for chat in chats {
            let key = WorkspaceChatID(workspace: workspaceID, chat: chat.id)
            if liveCodexAttention[key]?.reason == nil, liveCodexAttention[key] != nil {
                liveCodexAttention[key] = nil
            }
        }
        var completed: [WorkspaceAttention] = []
        for chat in chats where chat.status == .idle {
            guard let reply = verifiedReplies[chat.id],
                  let was = previous[chat.id], was == .active || was == .approval || was == .input else { continue }
            let key = WorkspaceChatID(workspace: workspaceID, chat: chat.id)
            if let last = reportedCodexCompletion[key], Date().timeIntervalSince(last) < 30 { continue }
            if let entry = codexCompleted(key, title: chat.title, reply: reply) { completed.append(entry) }
        }
        return completed
    }

    func pollCodex() async -> [WorkspaceAttention] {
        let endpoints: [(String, CodexLocalEndpoint)] = remotes.profiles.compactMap { profile in
            guard profile.kind == .codex, let bearer = remotes.bearer(for: profile),
                  let endpoint = CodexLocalEndpoint(remote: profile, bearer: bearer) else { return nil }
            return (profile.id.uuidString, endpoint)
        }
        var found: [WorkspaceAttention] = []
        let previous = codexChats
        await withTaskGroup(of: (String, [CodexChatSummary]?, [String: String]).self) { group in
            for (id, endpoint) in endpoints {
                group.addTask {
                    let client = endpoint.makeClient()
                    let result = try? await client.listSavedChats(maximumPages: 1)
                    var verified: [String: String] = [:]
                    if let result {
                        let busy = Set((previous[id] ?? []).filter {
                            $0.status == .active || $0.status == .approval || $0.status == .input
                        }.map(\.id))
                        for chat in result.lazy.filter({ $0.status == .idle && busy.contains($0.id) }).prefix(6) {
                            verified[chat.id] = try? await client.latestReply(in: chat.id)
                        }
                    }
                    await client.close()
                    return (id, result, verified)
                }
            }
            for await (id, chats, verified) in group {
                guard !Task.isCancelled else { break }
                if let chats { found += updateCodexChats(chats, workspaceID: id, verifiedReplies: verified) }
                else { codexChats[id] = nil }
            }
        }
        return found
    }

    private func recordReply(_ chat: WorkspaceChatID, title: String, date: Date, reply: String?) -> WorkspaceAttention? {
        guard let agent = agent(chat.workspace), agent.connector != "Demo",
              !(sceneIsActive && visibleChat == chat && !showingSwitcher && !showingAlerts) else { return nil }
        let entry = WorkspaceAttention(chat: chat, title: String(title.prefix(180)), reason: .reply, date: date,
                                       replyText: reply)
        store(entry)
        return entry
    }

    private func store(_ entry: WorkspaceAttention) {
        savedAttention.removeAll { $0.id == entry.id }
        savedAttention.append(entry)
        if savedAttention.count > 150 {
            savedAttention = Array(savedAttention.sorted { $0.date > $1.date }.prefix(150))
        }
        persistAttention()
    }

    private func persistRecent() {
        if let data = try? JSONEncoder().encode(recent) { defaults.set(data, forKey: "workspace.recent") }
    }

    private func persistAttention() {
        if let data = try? JSONEncoder().encode(savedAttention) { defaults.set(data, forKey: "workspace.attention") }
    }

    private func acknowledgeRelayReply(_ chat: WorkspaceChatID) {
        let IDs = relayedInbox.filter { $0.locator == chat && $0.reason == .reply }.map(\.receipt)
        let new = IDs.filter { !readRelayReplies.contains($0) }
        guard !new.isEmpty else { return }
        readRelayReplies = Array((new + readRelayReplies).prefix(250))
        defaults.set(readRelayReplies, forKey: "workspace.relay-read")
    }

    private static func icon(_ kind: RemoteKind) -> String {
        switch kind {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .hermes: "waveform"
        case .openClaw: "terminal"
        }
    }
}

private struct UnavailableWorkspaceTransport: JSONMessageTransport {
    let incoming = AsyncThrowingStream<Data, any Error> { $0.finish(throwing: ACPError.disconnected) }
    func send(_ message: Data) async throws { throw ACPError.disconnected }
}
