import Foundation
import Observation

public enum MessageReceipt: String, Equatable, Sendable {
    case delivered = "Delivered"
    case seen = "Seen"
}

public struct ChatEntry: Identifiable, Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case message(ChatRole, String)
        case tool(ToolActivity)
    }

    public let id = UUID()
    public fileprivate(set) var content: Content
    public fileprivate(set) var receipt: MessageReceipt?
}

public struct Transcript: Equatable, Sendable {
    public private(set) var entries: [ChatEntry] = []
    private var messageIndices: [String: Int] = [:]
    private var toolIndices: [String: Int] = [:]
    private var openMessage: Int?
    private var latestPromptIndex: Int?
    private var activePromptIndex: Int?

    public init() {}

    public var latestAssistantEntryID: UUID? {
        guard let latest = entries.last(where: {
            if case .message = $0.content { return true }
            return false
        }), case .message(.assistant, _) = latest.content else { return nil }
        return latest.id
    }

    public mutating func addPrompt(_ text: String) {
        openMessage = nil
        latestPromptIndex = entries.count
        activePromptIndex = entries.count
        entries.append(ChatEntry(content: .message(.user, text)))
    }

    public var hasCompletedToolCalls: Bool {
        toolIndices.values.contains { $0 < (activePromptIndex ?? entries.endIndex) }
    }

    public func visibleEntries(showCompletedToolCalls: Bool) -> [ChatEntry] {
        let activeStart = activePromptIndex ?? entries.endIndex
        return entries.enumerated().compactMap { index, entry in
            if case .tool = entry.content, !showCompletedToolCalls || index >= activeStart { return nil }
            return entry
        }
    }

    public var activeToolCalls: [ToolActivity] {
        guard let activePromptIndex else { return [] }
        return entries[activePromptIndex...].compactMap { entry in
            if case .tool(let activity) = entry.content { return activity }
            return nil
        }
    }

    fileprivate mutating func acknowledgePrompt() {
        guard let index = activePromptIndex, entries[index].receipt == nil else { return }
        entries[index].receipt = .delivered
    }

    fileprivate mutating func finishPrompt() {
        activePromptIndex = nil
    }

    public mutating func apply(_ event: ACPEvent) {
        switch event {
        case .message(_, let messageID, let role, let text):
            let index = messageID.flatMap { messageIndices[$0] } ?? (messageID == nil ? openMessage : nil)
            let messageIndex: Int
            if let index, case .message(let existingRole, let existing) = entries[index].content, existingRole == role {
                messageIndex = index
                entries[index].content = .message(role, existing + text)
            } else {
                messageIndex = entries.count
                openMessage = messageIndex
                if let messageID { messageIndices[messageID] = messageIndex }
                if role == .user { latestPromptIndex = messageIndex }
                entries.append(ChatEntry(content: .message(role, text), receipt: role == .user ? .delivered : nil))
            }
            if role == .assistant, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let latestPromptIndex, messageIndex > latestPromptIndex {
                entries[latestPromptIndex].receipt = .seen
            }
        case .tool(_, let activity):
            let toolIndex: Int
            if let index = toolIndices[activity.id], case .tool(let previous) = entries[index].content {
                toolIndex = index
                entries[index].content = .tool(ToolActivity(id: activity.id,
                    title: activity.title ?? previous.title, status: activity.status ?? previous.status))
            } else {
                toolIndex = entries.count
                openMessage = nil
                toolIndices[activity.id] = toolIndex
                entries.append(ChatEntry(content: .tool(activity)))
            }
            if let activePromptIndex, toolIndex > activePromptIndex { acknowledgePrompt() }
        case .permission, .permissionClosed, .configOptions, .context, .plan:
            break
        }
    }
}

@MainActor
@Observable
public final class AgentChatModel {
    public let target: AgentTarget
    public private(set) var selectedID: String
    public private(set) var sessions: [SessionSummary] = []
    public private(set) var listError: String?
    public private(set) var refreshingList = false
    public private(set) var creatingChat = false
    private var chats: [String: ChatState] = [:]
    public private(set) var completedReplies: [String: Date] = [:]
    public private(set) var pendingApprovalSince: [String: Date] = [:]
    public private(set) var workingChats = Set<String>()
    private var newlyCreatedOpenClawKeys: [String: String] = [:]
    @ObservationIgnored private var client: ACPClient?
    @ObservationIgnored private var makeClient: (@Sendable () -> ACPClient)?
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var mainPreload: Task<Void, Never>?

    public struct ChatState {
        public fileprivate(set) var transcript = Transcript()
        public fileprivate(set) var permissions: [PermissionRequest] = []
        public fileprivate(set) var configOptions: [SessionConfigOption] = []
        fileprivate var reportedModelName: String?
        public fileprivate(set) var context: ContextUsage?
        public fileprivate(set) var configuring = false
        public fileprivate(set) var configError: String?
        public fileprivate(set) var loading = false
        public fileprivate(set) var loaded = false
        public fileprivate(set) var working = false
        public fileprivate(set) var stopping = false
        public fileprivate(set) var error: String?
        public fileprivate(set) var notice: String?
        public fileprivate(set) var plan: [TurnPlanStep] = []

        public var modelName: String? {
            configOptions.first { $0.category == .model }?.currentName ?? reportedModelName
        }
        public var hasConfigChoices: Bool { configOptions.contains { !$0.choices.isEmpty } }

        fileprivate mutating func receive(_ event: ACPEvent) {
            switch event {
            case .message(_, _, .user, _) where working:
                transcript.acknowledgePrompt()
            case .message, .tool:
                transcript.apply(event)
            case .plan(_, let steps):
                transcript.acknowledgePrompt()
                plan = steps
            case .configOptions(_, let options):
                configOptions = options
            case .context(_, let usage):
                context = usage
            case .permission(let request):
                transcript.acknowledgePrompt()
                permissions.append(request)
            case .permissionClosed(_, let id):
                permissions.removeAll { $0.id == id }
            }
        }
    }

    public init(target: AgentTarget, client: ACPClient) {
        self.target = target
        self.client = client
        selectedID = target.mainSessionID
    }

    public init(target: AgentTarget, connect: @escaping @Sendable () -> ACPClient) {
        self.target = target
        selectedID = target.mainSessionID
        makeClient = connect
    }

    public init(target: AgentTarget, unavailable message: String) {
        self.target = target
        selectedID = target.mainSessionID
        client = nil
        chats[selectedID, default: ChatState()].error = message
    }

    deinit { observer?.cancel() }

    public var selected: ChatState { chats[selectedID] ?? ChatState() }

    public func title(for sessionID: String) -> String {
        sessionID == target.mainSessionID ? "Main Chat" :
            sessions.first { $0.id == sessionID }?.title ?? "Untitled chat"
    }
    public var mainActivity: String? {
        guard let main = chats[target.mainSessionID] else { return nil }
        if !main.permissions.isEmpty { return "Needs approval" }
        if main.working { return "Working" }
        return nil
    }
    public var title: String { title(for: selectedID) }

    public func selectMain() { selectedID = target.mainSessionID }

    public func showMain() async { await open(target.mainSessionID) }

    public func preloadMain() async {
        let main = target.mainSessionID
        guard mainPreload == nil, chats[main]?.loaded != true, chats[main]?.loading != true else { return }
        let preload = Task {
            defer { mainPreload = nil }
            await load(main)
        }
        mainPreload = preload
        await preload.value
    }

    public func open(_ sessionID: String) async {
        if makeClient != nil, sessionID != target.mainSessionID,
           !sessions.contains(where: { $0.id == sessionID && $0.cwd == target.cwd }) { return }
        selectedID = sessionID
        if sessionID == target.mainSessionID, let mainPreload {
            await mainPreload.value
            return
        }
        await load(sessionID)
    }

    private func load(_ sessionID: String) async {
        if client == nil { client = makeClient?() }
        guard let client, chats[sessionID]?.loaded != true, chats[sessionID]?.loading != true else { return }
        observe(client)
        chats[sessionID, default: ChatState()].loading = true
        chats[sessionID]?.error = nil
        defer { chats[sessionID]?.loading = false }
        do {
            let cwd = sessions.first { $0.id == sessionID }?.cwd ?? target.cwd
            let opened = try await client.load(sessionID: sessionID, cwd: cwd)
            markLoaded(opened)
        } catch {
            if !Task.isCancelled { chats[sessionID]?.error = error.localizedDescription }
            if makeClient != nil, !chats.values.contains(where: \.loaded),
               !chats.contains(where: { $0.key != sessionID && $0.value.loading }) {
                await client.close()
            }
        }
    }

    public func refreshSessions(maximumPages: Int? = nil) async {
        guard !refreshingList else { return }
        let existing = client
        guard let lookup = existing ?? makeClient?() else { listError = selected.error; return }
        refreshingList = true
        listError = nil
        defer { refreshingList = false }
        do {
            let listed = try await lookup.sessions(maximumPages: maximumPages)
            try Task.checkCancellation()
            let scoped = makeClient == nil ? listed : listed.filter { $0.cwd == target.cwd }
            if maximumPages != nil {
                let indexed = Set(scoped.map(\.id))
                sessions = scoped + sessions.filter { !indexed.contains($0.id) }
            } else {
                sessions = scoped
            }
        }
        catch { if !Task.isCancelled { listError = error.localizedDescription } }
        if existing == nil { await lookup.close() }
    }

    public func refreshTalkHistory(in sessionID: String) async {
        guard selectedID == sessionID, let client, selected.loaded, !selected.loading, !selected.working,
              !selected.configuring, selected.permissions.isEmpty else { return }
        chats[sessionID]?.loading = true
        defer { chats[sessionID]?.loading = false }
        do {
            let cwd = sessions.first { $0.id == sessionID }?.cwd ?? target.cwd
            let opened = try await client.load(sessionID: sessionID, cwd: cwd)
            guard self.client === client else { return }
            markLoaded(opened)
        } catch {
            if !Task.isCancelled, self.client === client {
                chats[sessionID]?.notice = "Voice ended, but chat history couldn’t refresh."
            }
        }
    }

    @discardableResult
    public func createChat(openClaw: Bool = false) async -> Bool {
        guard let client, !creatingChat else { return false }
        observe(client)
        creatingChat = true
        listError = nil
        defer { creatingChat = false }
        do {
            let selectedBeforeCreation = selectedID
            let nativeKey: String?
            if openClaw {
                let currentKey = try await openClawVoiceSessionKey(for: selectedBeforeCreation)
                let parts = currentKey.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, !parts[1].isEmpty,
                      parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }) else {
                    throw ACPError.rejected("OpenClaw didn’t report a valid agent for this chat.")
                }
                nativeKey = "agent:\(parts[1]):riptide-\(UUID().uuidString.lowercased())"
            } else {
                nativeKey = nil
            }
            let opened = try await client.newSession(cwd: target.cwd, nativeSessionKey: nativeKey)
            guard self.client === client else { throw ACPError.disconnected }
            let sessionID = opened.id
            markLoaded(opened)
            newlyCreatedOpenClawKeys[sessionID] = opened.nativeSessionKey
            sessions.insert(SessionSummary(id: sessionID, title: "Untitled chat", cwd: target.cwd,
                                           nativeSessionKey: opened.nativeSessionKey), at: 0)
            guard selectedID == selectedBeforeCreation else { return false }
            selectedID = sessionID
            return true
        } catch {
            listError = error.localizedDescription
            return false
        }
    }

    public func setConfigOption(_ configID: String, value: String, sessionID: String) async {
        guard let client, sessionID == selectedID, let chat = chats[sessionID],
              chat.loaded, !chat.loading, !chat.working, !chat.configuring,
              chat.configOptions.contains(where: { $0.id == configID && $0.currentValue != value
                  && $0.choices.contains(where: { $0.id == value }) }) else { return }
        chats[sessionID]?.configError = nil
        chats[sessionID]?.configuring = true
        defer { chats[sessionID]?.configuring = false }
        do {
            let options = try await client.setConfigOption(sessionID: sessionID, configID: configID, value: value)
            chats[sessionID]?.configOptions = options
        } catch {
            chats[sessionID]?.configError = error.localizedDescription
        }
    }

    public func submit(_ rawText: String, beforePrompt: (@MainActor () async -> Void)? = nil) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID = selectedID
        guard let client = preparePrompt(text, for: sessionID) else { return }
        Task {
            defer { finishPrompt(sessionID, from: client) }
            await beforePrompt?()
            guard self.client === client else { return }
            if chats[sessionID]?.stopping == true {
                chats[sessionID]?.notice = "Reply stopped."
                return
            }
            do {
                let reason = try await client.prompt(text, sessionID: sessionID)
                chats[sessionID]?.transcript.acknowledgePrompt()
                switch reason {
                case "end_turn":
                    if chats[sessionID]?.transcript.latestAssistantEntryID != nil {
                        completedReplies[sessionID] = .now
                    }
                case "cancelled": chats[sessionID]?.notice = "Reply stopped."
                case "max_tokens": chats[sessionID]?.notice = "The agent reached its reply limit."
                default: chats[sessionID]?.notice = "The agent ended this turn early."
                }
            } catch { chats[sessionID]?.error = error.localizedDescription }
        }
    }

    public func submitHermesVoice(_ rawText: String, in sessionID: String) async throws -> String {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client = preparePrompt(text, for: sessionID) else {
            throw ACPError.rejected("This chat is already working or no longer open.")
        }
        defer { finishPrompt(sessionID, from: client) }
        do {
            let reply = try await client.promptForVoice(text, sessionID: sessionID)
            chats[sessionID]?.transcript.acknowledgePrompt()
            return reply
        } catch {
            if !Task.isCancelled { chats[sessionID]?.error = error.localizedDescription }
            throw error
        }
    }

    public func openClawVoiceSessionKey(for sessionID: String) async throws -> String {
        guard let client, selectedID == sessionID, selected.loaded else { throw ACPError.disconnected }
        if let bound = newlyCreatedOpenClawKeys[sessionID] { return bound }
        let refreshed = try await client.sessions()
        guard selectedID == sessionID, self.client === client,
              let listed = refreshed.first(where: { $0.id == sessionID && $0.cwd == target.cwd }),
              let key = listed.nativeSessionKey ?? (listed.id.hasPrefix("agent:") ? listed.id : nil),
              key.hasPrefix("agent:") else {
            throw ACPError.rejected("The ACP host didn’t report this chat’s OpenClaw session key.")
        }
        return key
    }

    private func preparePrompt(_ text: String, for sessionID: String) -> ACPClient? {
        guard let client, sessionID == selectedID, !text.isEmpty, selected.loaded, !selected.loading,
              !selected.working, !selected.configuring else { return nil }
        if let index = sessions.firstIndex(where: { $0.id == sessionID && $0.title == "Untitled chat" }) {
            let row = sessions[index]
            sessions[index] = SessionSummary(id: sessionID, title: String(text.prefix(48)), cwd: row.cwd,
                                             nativeSessionKey: row.nativeSessionKey)
        }
        observe(client)
        chats[sessionID]?.transcript.addPrompt(text)
        chats[sessionID]?.working = true
        workingChats.insert(sessionID)
        chats[sessionID]?.plan = []
        chats[sessionID]?.error = nil
        chats[sessionID]?.notice = nil
        return client
    }

    private func finishPrompt(_ sessionID: String, from client: ACPClient) {
        guard self.client === client else { return }
        chats[sessionID]?.transcript.finishPrompt()
        chats[sessionID]?.working = false
        workingChats.remove(sessionID)
        chats[sessionID]?.stopping = false
    }

    public func stop() async {
        let sessionID = selectedID
        guard let client, selected.working, !selected.stopping else { return }
        chats[sessionID]?.stopping = true
        do { try await client.cancel(sessionID: sessionID) }
        catch {
            chats[sessionID]?.error = error.localizedDescription
            chats[sessionID]?.stopping = false
        }
    }

    public func answer(_ request: PermissionRequest, optionID: String?) async {
        guard selectedID == request.sessionID, let client else { return }
        do { try await client.resolve(request.id, optionID: optionID) }
        catch { chats[request.sessionID]?.error = error.localizedDescription }
    }

    private func observe(_ client: ACPClient) {
        guard observer == nil else { return }
        observer = Task { [weak self] in
            for await event in client.events {
                guard let self else { break }
                chats[event.sessionID, default: ChatState()].receive(event)
                switch event {
                case .permission:
                    if pendingApprovalSince[event.sessionID] == nil { pendingApprovalSince[event.sessionID] = .now }
                case .permissionClosed:
                    if chats[event.sessionID]?.permissions.isEmpty == true { pendingApprovalSince[event.sessionID] = nil }
                default:
                    break
                }
            }
            guard let self, self.makeClient != nil, self.client === client, !Task.isCancelled else { return }
            self.client = nil
            self.pendingApprovalSince.removeAll()
            self.workingChats.removeAll()
            self.newlyCreatedOpenClawKeys.removeAll()
            self.observer = nil
            for id in Array(self.chats.keys) {
                self.chats[id]?.transcript.finishPrompt()
                self.chats[id]?.loaded = false
                self.chats[id]?.working = false
                self.chats[id]?.stopping = false
                self.chats[id]?.permissions = []
                self.chats[id]?.error = "Connection closed. Reconnect to reopen this chat."
            }
        }
    }

    private func markLoaded(_ opened: OpenedSession) {
        var chat = chats[opened.id] ?? ChatState()
        chat.transcript = Transcript()
        for event in opened.events { chat.receive(event) }
        if let options = opened.configOptions { chat.configOptions = options }
        chat.reportedModelName = opened.reportedModelName
        chat.loaded = true
        chats[opened.id] = chat
    }
}
