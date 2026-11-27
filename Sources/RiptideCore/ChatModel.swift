import Foundation
import Observation

public enum MessageReceipt: String, Equatable, Sendable {
    case delivered = "Delivered"
    case seen = "Seen"
}

public struct QueuedChatMessage: Identifiable, Sendable {
    public let id = UUID()
    public let text: String
    public let attachments: [ChatAttachment]

    public init(text: String, attachments: [ChatAttachment] = []) {
        self.text = text
        self.attachments = attachments
    }

    public var displayText: String { ChatAttachment.messageText(text, attachments: attachments) }
}

public struct ChatEntry: Identifiable, Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case message(ChatRole, String)
        case tool(ToolActivity)
        case pairingReceipt(name: String, connected: Bool)
    }

    public let id = UUID()
    public fileprivate(set) var content: Content
    public fileprivate(set) var receipt: MessageReceipt?
    public fileprivate(set) var isAssistantProgress = false
}

public struct Transcript: Equatable, Sendable {
    public private(set) var entries: [ChatEntry] = []
    private var messageIndices: [String: Int] = [:]
    private var toolIndices: [String: Int] = [:]
    private var openMessage: Int?
    private var latestPromptIndex: Int?
    private var activePromptIndex: Int?
    private var visibleProgress: Set<UUID> = []

    public init() {}

    public var latestUserMessageID: UUID? {
        guard let latestPromptIndex else { return nil }
        return entries[latestPromptIndex].id
    }

    public var latestAssistantEntryID: UUID? {
        lastMessage(includingProgress: true)?.id
    }

    fileprivate var latestAssistantText: String? {
        guard let entry = lastMessage(includingProgress: false),
              case .message(.assistant, let text) = entry.content else { return nil }
        return text
    }

    private func lastMessage(includingProgress: Bool) -> ChatEntry? {
        guard let latest = entries.last(where: {
            if $0.isAssistantProgress {
                return includingProgress && visibleProgress.contains($0.id)
            }
            if case .message = $0.content { return true }
            return false
        }), case .message(.assistant, _) = latest.content else { return nil }
        return latest
    }

    public mutating func addPrompt(_ text: String) {
        openMessage = nil
        latestPromptIndex = entries.count
        activePromptIndex = entries.count
        entries.append(ChatEntry(content: .message(.user, text)))
    }

    fileprivate mutating func addPairingReceipt(name: String, connected: Bool) {
        openMessage = nil
        entries.append(ChatEntry(content: .pairingReceipt(name: name, connected: connected)))
    }

    public var hasCompletedToolCalls: Bool {
        toolIndices.values.contains { $0 < (activePromptIndex ?? entries.endIndex) }
    }

    public func visibleEntries(showCompletedToolCalls: Bool) -> [ChatEntry] {
        let activeStart = activePromptIndex ?? entries.endIndex
        return entries.enumerated().compactMap { index, entry in
            if case .tool = entry.content, !showCompletedToolCalls || index >= activeStart { return nil }
            if entry.isAssistantProgress, !visibleProgress.contains(entry.id) { return nil }
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

    fileprivate var hasUnseenPrompt: Bool {
        guard let latestPromptIndex else { return false }
        return entries[latestPromptIndex].receipt != .seen
    }

    fileprivate mutating func markPromptSeen() {
        guard let latestPromptIndex else { return }
        entries[latestPromptIndex].receipt = .seen
    }

    fileprivate mutating func beginObservedTurn() {
        activePromptIndex = entries.endIndex
    }

    fileprivate mutating func finishPrompt() {
        activePromptIndex = nil
        visibleProgress.removeAll()
    }

    fileprivate mutating func addSteering(_ text: String) {
        openMessage = nil
        latestPromptIndex = entries.count
        entries.append(ChatEntry(content: .message(.user, text), receipt: .delivered))
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
                markPromptSeen()
            }
        case .assistantProgress(_, let messageID, let text):
            let index = messageIndices[messageID] ?? entries.endIndex
            let entry = ChatEntry(content: .message(.assistant, text), isAssistantProgress: true)
            if index == entries.endIndex {
                messageIndices[messageID] = index
                entries.append(entry)
            } else {
                entries[index].content = entry.content
                entries[index].isAssistantProgress = true
            }
            openMessage = nil
            visibleProgress.insert(entries[index].id)
            if let latestPromptIndex, index > latestPromptIndex, !text.isEmpty { markPromptSeen() }
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
            if let latestPromptIndex, toolIndex > latestPromptIndex { markPromptSeen() }
        case .agentActivity, .permission:
            markPromptSeen()
        case .plan(_, let steps):
            if !steps.isEmpty { markPromptSeen() }
        case .permissionClosed, .configOptions, .context, .turnActivity:
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
    public private(set) var completedReplies: [String: CompletedReply] = [:]
    public private(set) var pendingApprovalSince: [String: Date] = [:]
    public private(set) var workingChats = Set<String>()
    private var newlyCreatedOpenClawKeys: [String: String] = [:]
    private var unlistedNewChats = Set<String>()
    @ObservationIgnored private var client: ACPClient?
    @ObservationIgnored private var makeClient: (@Sendable () -> ACPClient)?
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var liveEventsDuringLoad: [String: [ACPEvent]] = [:]
    @ObservationIgnored private var mainPreload: Task<Void, Never>?
    @ObservationIgnored private var catalogRefresh: (maximumPages: Int?, task: Task<Void, Never>)?
    @ObservationIgnored private var attachmentDeliveries: [String: @MainActor () -> Void] = [:]
    @ObservationIgnored private var prompts: [String: Task<Void, Never>] = [:]

    public struct CompletedReply: Equatable, Sendable {
        public let date: Date
        public let preview: String
    }

    public struct ChatState {
        public fileprivate(set) var transcript = Transcript()
        public fileprivate(set) var permissions: [PermissionRequest] = []
        public fileprivate(set) var configOptions: [SessionConfigOption] = []
        fileprivate var reportedModelName: String?
        public fileprivate(set) var acceptsImages = false
        public fileprivate(set) var context: ContextUsage?
        public fileprivate(set) var configuring = false
        public fileprivate(set) var configError: String?
        public fileprivate(set) var loading = false
        public fileprivate(set) var loaded = false
        public fileprivate(set) var connectionLost = false
        fileprivate var submittingPrompt = false
        fileprivate var agentWorking = false
        public fileprivate(set) var stopping = false
        fileprivate var preparingPrompt = false
        public fileprivate(set) var steering = false
        public fileprivate(set) var steeringError: String?
        public fileprivate(set) var queuedMessages: [QueuedChatMessage] = []
        public fileprivate(set) var sendingQueuedID: UUID?
        public fileprivate(set) var queuePaused = false
        public fileprivate(set) var error: String?
        public fileprivate(set) var notice: String?
        public fileprivate(set) var plan: [TurnPlanStep] = []

        public var working: Bool { submittingPrompt || agentWorking }
        public var canStop: Bool { submittingPrompt }

        public var modelName: String? {
            configOptions.first { $0.category == .model }?.currentName ?? reportedModelName
        }
        public var hasConfigChoices: Bool { configOptions.contains { !$0.choices.isEmpty } }

        fileprivate mutating func receive(_ event: ACPEvent, replaying: Bool = false) {
            switch event {
            case .turnActivity(_, let active):
                let wasWorking = working
                agentWorking = active
                guard !replaying, wasWorking != working else { return }
                if working { transcript.beginObservedTurn() }
                else { transcript.finishPrompt() }
            case .message(_, _, .user, _) where submittingPrompt:
                transcript.acknowledgePrompt()
            case .assistantProgress where !working:
                break
            case .assistantProgress:
                transcript.apply(event)
            case .message, .tool, .agentActivity:
                transcript.apply(event)
            case .plan(_, let steps):
                transcript.apply(event)
                plan = steps
            case .configOptions(_, let options):
                configOptions = options
            case .context(_, let usage):
                context = usage
            case .permission(let request):
                transcript.apply(event)
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
        guard chats[sessionID]?.loaded != true, chats[sessionID]?.loading != true else { return }
        if client == nil { client = makeClient?() }
        guard let client else { return }
        observe(client)
        chats[sessionID, default: ChatState()].loading = true
        chats[sessionID]?.error = nil
        liveEventsDuringLoad[sessionID] = []
        defer {
            if self.client === client {
                chats[sessionID]?.loading = false
                liveEventsDuringLoad.removeValue(forKey: sessionID)
            }
        }
        do {
            let cwd = sessions.first { $0.id == sessionID }?.cwd ?? target.cwd
            let opened = try await client.load(sessionID: sessionID, cwd: cwd)
            guard self.client === client else { return }
            markLoaded(opened)
        } catch {
            guard self.client === client else { return }
            if !Task.isCancelled { chats[sessionID]?.error = error.localizedDescription }
            if makeClient != nil, !chats.values.contains(where: \.loaded),
               !chats.contains(where: { $0.key != sessionID && $0.value.loading }) {
                await client.close()
            }
        }
    }

    public func refreshSessions(maximumPages: Int? = nil) async {
        guard !Task.isCancelled else { return }
        if let refresh = catalogRefresh {
            await refresh.task.value
            if maximumPages == nil, refresh.maximumPages != nil { await refreshSessions() }
            return
        }
        refreshingList = true
        let task = Task {
            defer {
                catalogRefresh = nil
                refreshingList = false
            }
            await readSessions(maximumPages: maximumPages)
        }
        catalogRefresh = (maximumPages, task)
        await task.value
    }

    private func readSessions(maximumPages: Int?) async {
        let existing = client
        guard let lookup = existing ?? makeClient?() else { listError = selected.error; return }
        listError = nil
        do {
            let listed = try await lookup.sessions(maximumPages: maximumPages)
            let scoped = makeClient == nil ? listed : listed.filter { $0.cwd == target.cwd }
            let indexed = Set(scoped.map(\.id))
            unlistedNewChats.subtract(indexed)
            // Some connectors only list a new chat once it has a message.
            sessions = scoped + sessions.filter {
                !indexed.contains($0.id) && (maximumPages != nil || unlistedNewChats.contains($0.id))
            }
        }
        catch { if !Task.isCancelled { listError = error.localizedDescription } }
        if existing == nil { await lookup.close() }
    }

    public func refreshTalkHistory(in sessionID: String) async {
        guard selectedID == sessionID, let client, selected.loaded, !selected.loading, !selected.working,
              !selected.configuring, selected.permissions.isEmpty else { return }
        chats[sessionID]?.loading = true
        liveEventsDuringLoad[sessionID] = []
        defer {
            if self.client === client {
                chats[sessionID]?.loading = false
                liveEventsDuringLoad.removeValue(forKey: sessionID)
            }
        }
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
        guard !creatingChat else { return false }
        if client == nil { client = makeClient?() }
        guard let client else { listError = selected.error; return false }
        observe(client)
        creatingChat = true
        listError = nil
        defer { creatingChat = false }
        do {
            let selectedBeforeCreation = selectedID
            let nativeKey: String?
            if openClaw {
                let currentKey = try await openClawSessionKey(for: selectedBeforeCreation, using: client)
                let parts = currentKey.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, !parts[1].isEmpty,
                      parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }) else {
                    throw ACPError.rejected("OpenClaw didn’t report a valid agent for this chat.")
                }
                nativeKey = "agent:\(parts[1]):riptide-\(UUID().uuidString.lowercased())"
            } else {
                nativeKey = nil
            }
            guard self.client === client, selectedID == selectedBeforeCreation else { return false }
            let opened = try await client.newSession(cwd: target.cwd, nativeSessionKey: nativeKey)
            guard self.client === client else { throw ACPError.disconnected }
            let sessionID = opened.id
            markLoaded(opened)
            newlyCreatedOpenClawKeys[sessionID] = opened.nativeSessionKey
            unlistedNewChats.insert(sessionID)
            sessions.removeAll { $0.id == sessionID }
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

    @discardableResult
    public func submit(_ rawText: String, attachments: [ChatAttachment] = [],
                       onSent: (@MainActor () -> Void)? = nil,
                       beforePrompt: (@MainActor () async -> Void)? = nil) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return startPrompt(text, attachments: attachments, in: selectedID, onSent: onSent, beforePrompt: beforePrompt)
    }

    @discardableResult
    private func startPrompt(_ text: String, attachments: [ChatAttachment] = [], in sessionID: String,
                             onSent: (@MainActor () -> Void)? = nil,
                             beforePrompt: (@MainActor () async -> Void)? = nil) -> Bool {
        let display = ChatAttachment.messageText(text, attachments: attachments)
        guard let client = preparePrompt(display, for: sessionID) else { return false }
        attachmentDeliveries[sessionID] = onSent
        chats[sessionID]?.preparingPrompt = beforePrompt != nil
        prompts[sessionID] = Task {
            var completed = false
            defer { finishPrompt(sessionID, from: client, advanceQueue: completed) }
            await beforePrompt?()
            guard self.client === client else { return }
            chats[sessionID]?.preparingPrompt = false
            if chats[sessionID]?.stopping == true {
                chats[sessionID]?.notice = "Reply stopped."
                return
            }
            do {
                let reason = try await client.prompt(text, sessionID: sessionID, attachments: attachments)
                guard self.client === client else { return }
                if reason != "cancelled" { attachmentDeliveries.removeValue(forKey: sessionID)?() }
                chats[sessionID]?.transcript.acknowledgePrompt()
                switch reason {
                case "end_turn":
                    completed = true
                    chats[sessionID]?.transcript.markPromptSeen()
                    if let reply = chats[sessionID]?.transcript.latestAssistantText,
                       let preview = WorkspaceAttention.preview(reply) {
                        completedReplies[sessionID] = CompletedReply(date: .now, preview: preview)
                    }
                case "cancelled": chats[sessionID]?.notice = "Reply stopped."
                case "max_tokens": chats[sessionID]?.notice = "The agent reached its reply limit."
                default: chats[sessionID]?.notice = "The agent ended this turn early."
                }
            } catch {
                if self.client === client { chats[sessionID]?.error = error.localizedDescription }
            }
        }
        return true
    }

    public func steer(_ rawText: String, in sessionID: String) async -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, let chat = chats[sessionID], sessionID == selectedID, !text.isEmpty,
              chat.loaded, !chat.loading, !chat.configuring, !chat.stopping, !chat.steering else { return false }
        if !chat.working { return startPrompt(text, in: sessionID) }
        guard chat.canStop else { return false }
        if chat.preparingPrompt {
            chats[sessionID]?.steeringError = "This reply is still starting. Try again in a moment."
            return false
        }
        let prompt = prompts[sessionID]
        chats[sessionID]?.steering = true
        chats[sessionID]?.steeringError = nil
        defer {
            if self.client === client {
                chats[sessionID]?.steering = false
                drainQueue(in: sessionID)
            }
        }
        do {
            let steered = try await client.steer(text, sessionID: sessionID)
            guard self.client === client else { return false }
            if steered {
                chats[sessionID]?.transcript.addSteering(text)
                return true
            }
            await prompt?.value
            guard self.client === client, !Task.isCancelled else { return false }
            return startPrompt(text, in: sessionID)
        } catch {
            if self.client === client { chats[sessionID]?.steeringError = error.localizedDescription }
            return false
        }
    }

    public func enqueue(_ rawText: String, attachments: [ChatAttachment] = [], in sessionID: String) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard chats[sessionID]?.loaded == true, !text.isEmpty || !attachments.isEmpty else { return false }
        chats[sessionID]?.queuedMessages.append(QueuedChatMessage(text: text, attachments: attachments))
        chats[sessionID]?.steeringError = nil
        drainQueue(in: sessionID)
        return true
    }

    public func removeQueuedMessage(_ id: UUID, in sessionID: String) {
        guard chats[sessionID]?.sendingQueuedID != id else { return }
        chats[sessionID]?.queuedMessages.removeAll { $0.id == id }
        if chats[sessionID]?.queuedMessages.isEmpty == true { chats[sessionID]?.queuePaused = false }
    }

    public func resumeQueue(in sessionID: String) {
        chats[sessionID]?.queuePaused = false
        drainQueue(in: sessionID)
    }

    private func drainQueue(in sessionID: String) {
        guard let chat = chats[sessionID], !chat.steering, !chat.queuePaused,
              let message = chat.queuedMessages.first else { return }
        if message.attachments.isEmpty {
            if startPrompt(message.text, in: sessionID) { removeQueuedMessage(message.id, in: sessionID) }
            return
        }
        let started = startPrompt(message.text, attachments: message.attachments, in: sessionID, onSent: { [weak self] in
            self?.chats[sessionID]?.sendingQueuedID = nil
            self?.removeQueuedMessage(message.id, in: sessionID)
        })
        if started { chats[sessionID]?.sendingQueuedID = message.id }
    }

    public func submitHermesVoice(_ rawText: String, in sessionID: String) async throws -> String {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sessionID == selectedID, let client = preparePrompt(text, for: sessionID) else {
            throw ACPError.rejected("This chat is already working or no longer open.")
        }
        var completed = false
        defer { finishPrompt(sessionID, from: client, advanceQueue: completed) }
        do {
            let reply = try await client.promptForVoice(text, sessionID: sessionID)
            chats[sessionID]?.transcript.acknowledgePrompt()
            completed = !reply.isEmpty
            return reply
        } catch {
            if !Task.isCancelled { chats[sessionID]?.error = error.localizedDescription }
            throw error
        }
    }

    public func openClawVoiceSessionKey(for sessionID: String) async throws -> String {
        guard let client, selectedID == sessionID, selected.loaded else { throw ACPError.disconnected }
        let key = try await openClawSessionKey(for: sessionID, using: client)
        guard selectedID == sessionID, selected.loaded else { throw ACPError.disconnected }
        return key
    }

    private func openClawSessionKey(for sessionID: String, using client: ACPClient) async throws -> String {
        if let bound = newlyCreatedOpenClawKeys[sessionID] { return bound }
        let refreshed = try await client.sessions()
        guard self.client === client,
              let listed = refreshed.first(where: { $0.id == sessionID && $0.cwd == target.cwd }),
              let key = listed.nativeSessionKey ?? (listed.id.hasPrefix("agent:") ? listed.id : nil),
              key.hasPrefix("agent:") else {
            throw ACPError.rejected("The ACP host didn’t report this chat’s OpenClaw session key.")
        }
        return key
    }

    private func preparePrompt(_ text: String, for sessionID: String) -> ACPClient? {
        guard let client, let chat = chats[sessionID], !text.isEmpty, chat.loaded, !chat.loading,
              !chat.working, !chat.configuring else { return nil }
        if let index = sessions.firstIndex(where: { $0.id == sessionID && $0.title == "Untitled chat" }) {
            let row = sessions[index]
            sessions[index] = SessionSummary(id: sessionID, title: String(text.prefix(48)), cwd: row.cwd,
                                             nativeSessionKey: row.nativeSessionKey)
        }
        observe(client)
        chats[sessionID]?.transcript.addPrompt(text)
        chats[sessionID]?.submittingPrompt = true
        recordWorkingState(sessionID)
        chats[sessionID]?.plan = []
        chats[sessionID]?.error = nil
        chats[sessionID]?.steeringError = nil
        chats[sessionID]?.notice = nil
        return client
    }

    private func finishPrompt(_ sessionID: String, from client: ACPClient, advanceQueue: Bool) {
        guard self.client === client else { return }
        prompts[sessionID] = nil
        attachmentDeliveries.removeValue(forKey: sessionID)
        guard var chat = chats[sessionID] else { return }
        chat.sendingQueuedID = nil
        chat.submittingPrompt = false
        chat.stopping = false
        if !chat.working { chat.transcript.finishPrompt() }
        if !advanceQueue, !chat.queuedMessages.isEmpty { chat.queuePaused = true }
        chats[sessionID] = chat
        recordWorkingState(sessionID)
        if advanceQueue { drainQueue(in: sessionID) }
    }

    public func stop() async {
        let sessionID = selectedID
        guard let client, selected.canStop, !selected.stopping else { return }
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

    public func answerPairing(_ request: PermissionRequest, connectedName: String?) async {
        guard let client, let invitation = HermesPairingInvitation(request),
              chats[request.sessionID]?.permissions.contains(request) == true else { return }
        chats[request.sessionID]?.transcript.addPairingReceipt(name: connectedName ?? invitation.displayName,
                                                              connected: connectedName != nil)
        do {
            try await client.resolve(request.id, optionID: connectedName == nil ? "skip" : invitation.optionID)
        } catch {
            chats[request.sessionID]?.error = error.localizedDescription
        }
    }

    private func observe(_ client: ACPClient) {
        guard observer == nil else { return }
        observer = Task { [weak self] in
            for await event in client.events {
                guard let self else { break }
                if liveEventsDuringLoad[event.sessionID] != nil {
                    // The stream can reach the model before the task awaiting session/load.
                    liveEventsDuringLoad[event.sessionID]?.append(event)
                } else {
                    receiveLive(event)
                }
            }
            guard let self, self.makeClient != nil, self.client === client, !Task.isCancelled else { return }
            self.client = nil
            self.pendingApprovalSince.removeAll()
            self.workingChats.removeAll()
            self.prompts.removeAll()
            self.attachmentDeliveries.removeAll()
            self.liveEventsDuringLoad.removeAll()
            self.newlyCreatedOpenClawKeys.removeAll()
            self.observer = nil
            for id in Array(self.chats.keys) {
                guard var chat = self.chats[id] else { continue }
                if chat.loaded {
                    chat.connectionLost = true
                    chat.error = "Connection closed. Reconnect to reopen this chat."
                } else if chat.loading && chat.error == nil {
                    chat.error = ACPError.disconnected.localizedDescription
                }
                chat.transcript.finishPrompt()
                chat.loading = false
                chat.loaded = false
                chat.submittingPrompt = false
                chat.agentWorking = false
                chat.stopping = false
                chat.preparingPrompt = false
                chat.steering = false
                chat.sendingQueuedID = nil
                chat.queuePaused = !chat.queuedMessages.isEmpty
                chat.permissions = []
                self.chats[id] = chat
            }
        }
    }

    private func receiveLive(_ event: ACPEvent) {
        let sessionID = event.sessionID
        if case .agentActivity = event, chats[sessionID]?.transcript.hasUnseenPrompt != true { return }
        chats[sessionID, default: ChatState()].receive(event)
        switch event {
        case .message, .assistantProgress:
            attachmentDeliveries.removeValue(forKey: sessionID)?()
        case .turnActivity:
            recordWorkingState(sessionID)
            drainQueue(in: sessionID)
        case .permission, .permissionClosed:
            recordApprovalState(sessionID)
        default:
            break
        }
    }

    private func recordWorkingState(_ sessionID: String) {
        if chats[sessionID]?.working == true { workingChats.insert(sessionID) }
        else { workingChats.remove(sessionID) }
    }

    private func recordApprovalState(_ sessionID: String) {
        if chats[sessionID]?.permissions.isEmpty != false { pendingApprovalSince[sessionID] = nil }
        else if pendingApprovalSince[sessionID] == nil { pendingApprovalSince[sessionID] = .now }
    }

    private func markLoaded(_ opened: OpenedSession) {
        var chat = chats[opened.id] ?? ChatState()
        chat.transcript = Transcript()
        for event in opened.events { chat.receive(event, replaying: true) }
        if chat.agentWorking { chat.transcript.beginObservedTurn() }
        if let options = opened.configOptions { chat.configOptions = options }
        chat.reportedModelName = opened.reportedModelName
        chat.acceptsImages = opened.acceptsImages
        chat.loaded = true
        chat.loading = false
        chat.connectionLost = false
        chats[opened.id] = chat
        recordWorkingState(opened.id)
        recordApprovalState(opened.id)
        for event in liveEventsDuringLoad.removeValue(forKey: opened.id) ?? [] { receiveLive(event) }
    }
}
