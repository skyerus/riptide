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
    fileprivate var confirmedUndelivered = false
    fileprivate var waitingForConnection = false

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
        case contextCompaction(ContextCompaction)
        case pairingReceipt(name: String, connected: Bool)
    }

    public let id = UUID()
    public fileprivate(set) var content: Content
    public fileprivate(set) var photos: [TranscriptPhoto] = []
    public fileprivate(set) var receipt: MessageReceipt?
    public fileprivate(set) var isAssistantProgress = false

    public var isConversationMessage: Bool {
        guard !isAssistantProgress, case .message = content else { return false }
        return true
    }
}

public struct Transcript: Equatable, Sendable {
    public private(set) var entries: [ChatEntry] = []
    public private(set) var activeCompaction: ContextCompaction?
    private var messageIndices: [String: Int] = [:]
    private var toolIndices: [String: Int] = [:]
    private var completedCompactionIDs: Set<String> = []
    private var openMessage: Int?
    private var latestPromptIndex: Int?
    private var activePromptIndex: Int?
    private var visibleProgress: Set<UUID> = []

    public init() {}

    public var latestUserMessageID: UUID? {
        guard let latestPromptIndex else { return nil }
        return entries[latestPromptIndex].id
    }

    public var firstActiveOutputID: UUID? {
        guard let activePromptIndex else { return nil }
        return entries[activePromptIndex...].first { entry in
            switch entry.content {
            case .message(.assistant, _):
                showsMessage(entry)
            case .contextCompaction:
                true
            default:
                false
            }
        }?.id
    }

    fileprivate var activePromptID: UUID? {
        guard let activePromptIndex, entries.indices.contains(activePromptIndex) else { return nil }
        return entries[activePromptIndex].id
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

    public mutating func addPrompt(_ text: String, photos: [TranscriptPhoto] = []) {
        openMessage = nil
        latestPromptIndex = entries.count
        activePromptIndex = entries.count
        entries.append(ChatEntry(content: .message(.user, text), photos: photos))
    }

    fileprivate mutating func restorePhotos(from store: SentPhotoStore, in sessionID: String) {
        for index in entries.indices {
            guard case .message(.user, let text) = entries[index].content,
                  text.contains(ACPClient.photoReferencePrefix) else { continue }
            var lines = text.components(separatedBy: "\n")
            guard let reference = lines.firstIndex(where: {
                $0.hasPrefix(ACPClient.photoReferencePrefix) && $0.hasSuffix(ACPClient.photoReferenceSuffix)
                    && UUID(uuidString: String($0.dropFirst(ACPClient.photoReferencePrefix.count).dropLast())) != nil
            }), let id = UUID(uuidString: String(lines[reference].dropFirst(ACPClient.photoReferencePrefix.count).dropLast()))
            else { continue }
            if let message = store.read(id: id.uuidString, chat: sessionID) {
                entries[index].content = .message(.user, message.text)
                entries[index].photos = message.photos
            } else {
                lines.remove(at: reference)
                entries[index].content = .message(.user, lines.joined(separator: "\n"))
            }
        }
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
            if !showsMessage(entry) { return nil }
            return entry
        }
    }

    private func showsMessage(_ entry: ChatEntry) -> Bool {
        !entry.isAssistantProgress || visibleProgress.contains(entry.id)
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
        activeCompaction = nil
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
        case .contextCompaction(_, let compaction):
            guard !completedCompactionIDs.contains(compaction.id) else { return }
            openMessage = nil
            if compaction.isRunning {
                if activeCompaction?.id != compaction.id { activeCompaction = compaction }
            } else {
                let completed: ContextCompaction
                if let activeCompaction, activeCompaction.id == compaction.id {
                    completed = activeCompaction.merging(compaction)
                    self.activeCompaction = nil
                } else {
                    completed = compaction
                }
                completedCompactionIDs.insert(compaction.id)
                entries.append(ChatEntry(content: .contextCompaction(completed)))
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
            if let latestPromptIndex, toolIndex > latestPromptIndex { markPromptSeen() }
        case .agentActivity, .permission:
            markPromptSeen()
        case .plan(_, let steps):
            if !steps.isEmpty { markPromptSeen() }
        case .permissionClosed, .configOptions, .context, .turnActivity, .replyTimedOut:
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
    @ObservationIgnored private var connectionInUse = false
    @ObservationIgnored private var voiceConnectionInUse = false
    @ObservationIgnored private var idleTimeout: Duration?
    @ObservationIgnored private var idleDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var historyCache: ChatHistoryCache?
    @ObservationIgnored private var liveEventsDuringLoad: [String: [ACPEvent]] = [:]
    @ObservationIgnored private var openings: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var catalogRefresh: (maximumPages: Int?, client: ACPClient, task: Task<Void, Never>)?
    private var photoStore: SentPhotoStore { SentPhotoStore(workspace: target.id) }
    @ObservationIgnored private var attachmentDeliveries: [String: @MainActor () -> Void] = [:]
    @ObservationIgnored private var prompts: [String: Task<Void, Never>] = [:]

    public struct CompletedReply: Equatable, Sendable {
        public let date: Date
        public let preview: String
    }

    public struct ChatState {
        public fileprivate(set) var transcript = Transcript()
        fileprivate var provisionalTranscript: Transcript?
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
        public fileprivate(set) var turnStartedAt: Date?
        fileprivate var submittingPrompt = false
        fileprivate var agentWorking = false
        fileprivate var steerAdmissionID: String?
        public fileprivate(set) var stopping = false
        fileprivate var preparingPrompt = false
        public fileprivate(set) var sendingAttachmentDraft = false
        public fileprivate(set) var steering = false
        public fileprivate(set) var steeringError: String?
        public fileprivate(set) var replyTimedOut = false
        public fileprivate(set) var uncertainFollowUp: String?
        public fileprivate(set) var queuedMessages: [QueuedChatMessage] = []
        public fileprivate(set) var sendingQueuedID: UUID?
        public fileprivate(set) var queuePaused = false
        public fileprivate(set) var error: String?
        public fileprivate(set) var notice: String?
        public fileprivate(set) var plan: [TurnPlanStep] = []

        public var working: Bool { submittingPrompt || agentWorking }
        public var displayTranscript: Transcript { provisionalTranscript ?? transcript }
        public var canStop: Bool { submittingPrompt }
        public var canSteer: Bool { submittingPrompt || steerAdmissionID != nil }

        public var modelName: String? {
            configOptions.first { $0.category == .model }?.currentName ?? reportedModelName
        }
        public var hasConfigChoices: Bool { configOptions.contains { !$0.choices.isEmpty } }

        fileprivate mutating func receive(_ event: ACPEvent, replaying: Bool = false) {
            switch event {
            case .turnActivity(_, let active, let admissionID):
                let wasWorking = working
                agentWorking = active
                steerAdmissionID = admissionID
                guard wasWorking != working else { return }
                turnStartedAt = working ? .now : nil
                if working {
                    guard !replaying else { return }
                    replyTimedOut = false
                    uncertainFollowUp = nil
                    transcript.beginObservedTurn()
                }
                else { transcript.finishPrompt() }
            case .replyTimedOut:
                replyTimedOut = true
                queuePaused = !queuedMessages.isEmpty
            case .message(_, _, .user, _) where submittingPrompt:
                transcript.acknowledgePrompt()
            case .assistantProgress where !working:
                break
            case .assistantProgress:
                transcript.apply(event)
            case .message, .tool, .agentActivity, .contextCompaction:
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

    public init(target: AgentTarget, idleTimeout: Duration = .seconds(3_600), historyCache: ChatHistoryCache? = nil,
                connect: @escaping @Sendable () -> ACPClient) {
        self.target = target
        selectedID = target.mainSessionID
        self.idleTimeout = idleTimeout
        self.historyCache = historyCache
        makeClient = connect
    }

    public init(target: AgentTarget, unavailable message: String) {
        self.target = target
        selectedID = target.mainSessionID
        client = nil
        chats[selectedID, default: ChatState()].error = message
    }

    deinit {
        observer?.cancel()
        idleTask?.cancel()
    }

    public var selected: ChatState { chats[selectedID] ?? ChatState() }

    public func removeCachedHistory() {
        historyCache?.removeWorkspace()
        historyCache = nil
    }

    public func disconnect() {
        for task in openings.values { task.cancel() }
        catalogRefresh?.task.cancel()
        observer?.cancel()
        let previous = client
        clearConnection()
        if let previous { Task { await previous.close() } }
    }

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

    public func setConnectionInUse(_ inUse: Bool) {
        guard inUse != connectionInUse else { return }
        // The timer may not have run while iOS suspended the app.
        if inUse { expireIdleConnection() }
        connectionInUse = inUse
        scheduleIdleExpiration()
    }

    public func isLoaded(_ sessionID: String) -> Bool { chats[sessionID]?.loaded == true }

    public func recentMessages(in sessionID: String) -> [ChatEntry] {
        Array(chats[sessionID]?.transcript.entries.suffix(16) ?? [])
    }

    public func messageCount(in sessionID: String) -> Int {
        chats[sessionID]?.transcript.entries.count { $0.isConversationMessage } ?? 0
    }

    public func setVoiceConnectionInUse(_ inUse: Bool) {
        voiceConnectionInUse = inUse
        scheduleIdleExpiration()
    }

    public func preloadMain() async {
        await beginOpening(target.mainSessionID)?.value
    }

    public func prepareToOpen(_ sessionID: String) {
        guard makeClient != nil, sessionID == target.mainSessionID || listsChat(sessionID) else { return }
        _ = beginOpening(sessionID)
    }

    public func open(_ sessionID: String) async {
        if makeClient != nil, sessionID != target.mainSessionID, !listsChat(sessionID) { return }
        selectedID = sessionID
        await beginOpening(sessionID)?.value
    }

    public func openSavedChat(_ sessionID: String) async -> Bool {
        guard !Task.isCancelled else { return false }
        if !listsChat(sessionID) {
            if let cached = historyCache?.read(sessionID), chats[sessionID]?.loaded != true {
                showProvisionalHistory(ACPClient.historyEvents(cached.updates, sessionID: sessionID), in: sessionID)
                selectedID = sessionID
            }
            // Adopt an in-flight catalog connection, or keep the one used to look up this chat.
            guard connectIfNeeded() != nil else { return false }
            await refreshSessions()
        }
        guard !Task.isCancelled, listsChat(sessionID) else { return false }
        await open(sessionID)
        return true
    }

    private func listsChat(_ sessionID: String) -> Bool {
        sessions.contains { $0.id == sessionID && (makeClient == nil || $0.cwd == target.cwd) }
    }

    private func connectIfNeeded() -> ACPClient? {
        expireIdleConnection()
        guard let connection = client ?? catalogRefresh?.client ?? makeClient?() else { return nil }
        client = connection
        observe(connection)
        return connection
    }

    private func beginOpening(_ sessionID: String) -> Task<Void, Never>? {
        guard !Task.isCancelled else { return nil }
        if let opening = openings[sessionID] { return opening }
        expireIdleConnection()
        guard chats[sessionID]?.loaded != true else { return nil }
        let opening = Task {
            defer { openings[sessionID] = nil }
            await load(sessionID)
        }
        openings[sessionID] = opening
        return opening
    }

    private func load(_ sessionID: String, allowFastResume: Bool = true) async {
        guard !Task.isCancelled else { return }
        expireIdleConnection()
        guard chats[sessionID]?.loaded != true, chats[sessionID]?.loading != true else { return }
        guard let client = connectIfNeeded() else { return }
        let cached = historyCache?.read(sessionID)
        if let cached, chats[sessionID]?.transcript.entries.isEmpty != false,
           chats[sessionID]?.provisionalTranscript == nil {
            showProvisionalHistory(ACPClient.historyEvents(cached.updates, sessionID: sessionID), in: sessionID)
        }
        chats[sessionID, default: ChatState()].loading = true
        chats[sessionID]?.error = nil
        liveEventsDuringLoad[sessionID] = []
        defer {
            if self.client === client {
                chats[sessionID]?.loading = false
                liveEventsDuringLoad.removeValue(forKey: sessionID)
            }
        }
        let cwd = sessions.first { $0.id == sessionID }?.cwd ?? target.cwd
        let fastResume = allowFastResume && historyCache != nil
        let preview = fastResume ? Task { [weak self] in
            guard let events = try? await client.recentHistory(sessionID: sessionID, cwd: cwd),
                  let self, !Task.isCancelled, self.client === client, chats[sessionID]?.loading == true else { return }
            showProvisionalHistory(events, in: sessionID)
        } : nil
        defer { preview?.cancel() }
        do {
            let opened = try await client.load(sessionID: sessionID, cwd: cwd, cachedHistory: cached, fastResume: fastResume)
            guard self.client === client else { return }
            markLoaded(opened)
            if let snapshot = opened.historySnapshot, snapshot.checkpoint != cached?.checkpoint {
                historyCache?.write(snapshot, chat: sessionID)
            }
        } catch ACPError.fastResumeDisconnected where makeClient != nil && !Task.isCancelled {
            guard self.client === client || self.client == nil else { return }
            preview?.cancel()
            if self.client === client {
                observer?.cancel()
                clearConnection()
            }
            Task { await client.close() }
            await load(sessionID, allowFastResume: false)
        } catch {
            guard self.client === client else { return }
            if !Task.isCancelled { chats[sessionID]?.error = error.localizedDescription }
            if makeClient != nil, !chats.values.contains(where: \.loaded),
               !chats.contains(where: { $0.key != sessionID && $0.value.loading }) {
                await client.close()
            }
        }
    }

    private func showProvisionalHistory(_ events: [ACPEvent], in sessionID: String) {
        var transcript = Transcript()
        for event in events { transcript.apply(event) }
        guard !transcript.entries.isEmpty else { return }
        transcript.restorePhotos(from: photoStore, in: sessionID)
        chats[sessionID, default: ChatState()].provisionalTranscript = transcript
    }

    public func refreshSessions(maximumPages: Int? = nil) async {
        guard !Task.isCancelled else { return }
        if let refresh = catalogRefresh {
            await refresh.task.value
            if maximumPages == nil, refresh.maximumPages != nil { await refreshSessions() }
            return
        }
        guard let lookup = client ?? makeClient?() else { listError = selected.error; return }
        refreshingList = true
        let task = Task {
            let listed = await readSessions(using: lookup, maximumPages: maximumPages)
            catalogRefresh = nil
            refreshingList = false
            if client !== lookup {
                await lookup.close()
            } else if !listed, makeClient != nil, !creatingChat, !chats.values.contains(where: { $0.loaded || $0.loading }) {
                observer?.cancel()
                clearConnection()
                await lookup.close()
            }
        }
        catalogRefresh = (maximumPages, lookup, task)
        await task.value
    }

    private func readSessions(using lookup: ACPClient, maximumPages: Int?) async -> Bool {
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
            return true
        } catch {
            if !Task.isCancelled { listError = error.localizedDescription }
            return false
        }
    }

    public func refreshTalkHistory(in sessionID: String) async {
        guard let chat = chats[sessionID], let client, chat.loaded, !chat.loading, !chat.working,
              !chat.configuring, chat.permissions.isEmpty else { return }
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
        let previous = selectedID
        guard let id = await createSideChat(openClaw: openClaw), selectedID == previous else { return false }
        selectedID = id
        return true
    }

    public func createSideChat(openClaw: Bool = false) async -> String? {
        guard !creatingChat, !Task.isCancelled else { return nil }
        guard let client = connectIfNeeded() else { listError = selected.error; return nil }
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
            guard self.client === client, selectedID == selectedBeforeCreation else { return nil }
            let opened = try await client.newSession(cwd: target.cwd, nativeSessionKey: nativeKey)
            guard self.client === client else { throw ACPError.disconnected }
            let sessionID = opened.id
            markLoaded(opened)
            newlyCreatedOpenClawKeys[sessionID] = opened.nativeSessionKey
            unlistedNewChats.insert(sessionID)
            sessions.removeAll { $0.id == sessionID }
            sessions.insert(SessionSummary(id: sessionID, title: "Untitled chat", cwd: target.cwd,
                                           nativeSessionKey: opened.nativeSessionKey), at: 0)
            return sessionID
        } catch {
            listError = error.localizedDescription
            return nil
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
                       onWritten: (@MainActor @Sendable () -> Void)? = nil,
                       onRejected: (@MainActor @Sendable () -> Void)? = nil,
                       beforePrompt: (@MainActor () async -> Void)? = nil) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return startPrompt(text, attachments: attachments, in: selectedID, onSent: onSent,
                           onWritten: onWritten, onRejected: onRejected, beforePrompt: beforePrompt)
    }

    @discardableResult
    private func startPrompt(_ text: String, attachments: [ChatAttachment] = [], in sessionID: String,
                             onSent: (@MainActor () -> Void)? = nil,
                             onWritten: (@MainActor @Sendable () -> Void)? = nil,
                             onRejected: (@MainActor @Sendable () -> Void)? = nil,
                             beforePrompt: (@MainActor () async -> Void)? = nil) -> Bool {
        let message = SentPhotoMessage(text: text, attachments: attachments)
        guard let client = preparePrompt(message.text, photos: message.photos, for: sessionID) else { return false }
        let entryID = chats[sessionID]?.transcript.activePromptID
        let photoID = message.photos.isEmpty ? nil : entryID
        attachmentDeliveries[sessionID] = onSent
        chats[sessionID]?.preparingPrompt = beforePrompt != nil
        chats[sessionID]?.sendingAttachmentDraft = onWritten != nil
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
                if let photoID { try photoStore.save(message, id: photoID.uuidString, chat: sessionID) }
                let completion = try await client.promptWithDelivery(text, sessionID: sessionID, attachments: attachments,
                                                                     photoID: photoID) {
                    await self.promptWritten(in: sessionID, entryID: entryID, onWritten: onWritten)
                }
                guard self.client === client else { return }
                let reason = completion.reason
                if reason != "cancelled" {
                    promptWritten(in: sessionID, entryID: entryID, onWritten: onWritten)
                    attachmentDeliveries.removeValue(forKey: sessionID)?()
                }
                chats[sessionID]?.transcript.acknowledgePrompt()
                if completion.timedOut {
                    chats[sessionID]?.replyTimedOut = true
                    return
                }
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
                guard self.client === client else { return }
                if let error = error as? ACPError,
                   chats[sessionID]?.transcript.entries.first(where: { $0.id == entryID })?.receipt == nil {
                    switch error {
                    case .rejected, .invalidParameters, .methodUnavailable:
                        onRejected?()
                        if let photoID { photoStore.remove(id: photoID.uuidString, chat: sessionID) }
                    default: break
                    }
                }
                chats[sessionID]?.error = error.localizedDescription
            }
        }
        return true
    }

    private func promptWritten(in sessionID: String, entryID: UUID?,
                               onWritten: (@MainActor @Sendable () -> Void)?) {
        guard let onWritten, let entryID, let chat = chats[sessionID], chat.submittingPrompt,
              chat.sendingAttachmentDraft, chat.transcript.activePromptID == entryID else { return }
        chats[sessionID]?.sendingAttachmentDraft = false
        onWritten()
    }

    public func steer(_ rawText: String, in sessionID: String) async -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, let chat = chats[sessionID], sessionID == selectedID, !text.isEmpty,
              chat.loaded, !chat.loading, !chat.configuring, !chat.stopping, !chat.steering else { return false }
        if !chat.working { return startPrompt(text, in: sessionID) }
        guard chat.canSteer else {
            chats[sessionID]?.steeringError = "This reply can’t be steered. Use Queue to send your follow-up."
            return false
        }
        if chat.preparingPrompt {
            chats[sessionID]?.steeringError = "This reply is still starting. Try again in a moment."
            return false
        }
        let prompt = prompts[sessionID]
        let observedAdmissionID = chat.submittingPrompt ? nil : chat.steerAdmissionID
        chats[sessionID]?.steering = true
        chats[sessionID]?.steeringError = nil
        defer {
            if self.client === client {
                chats[sessionID]?.steering = false
                drainQueue(in: sessionID)
            }
        }
        do {
            let outcome = try await client.steerOutcome(text, sessionID: sessionID, observedAdmissionID: observedAdmissionID)
            guard self.client === client else { return false }
            if outcome == .accepted {
                chats[sessionID]?.transcript.addSteering(text)
                return true
            }
            if outcome == .notDelivered {
                if startPrompt(text, in: sessionID) { return true }
                var followUp = QueuedChatMessage(text: text)
                followUp.confirmedUndelivered = true
                chats[sessionID]?.queuedMessages.append(followUp)
                return true
            }
            await prompt?.value
            guard self.client === client, !Task.isCancelled else { return false }
            if observedAdmissionID != nil, chats[sessionID]?.working == true {
                chats[sessionID]?.steeringError = "That reply ended before it could be steered. Your draft is still here."
                return false
            }
            return startPrompt(text, in: sessionID)
        } catch {
            if self.client === client {
                chats[sessionID]?.uncertainFollowUp = text
                chats[sessionID]?.steeringError = error.localizedDescription
            }
            return false
        }
    }

    public func continueAfterTimeout(in sessionID: String) -> Bool {
        guard let chat = chats[sessionID], chat.replyTimedOut, !chat.steering else { return false }
        var prompt = "Continue the previous request. First verify what already happened and only perform the remaining work."
        if let followUp = chat.uncertainFollowUp {
            prompt += "\n\nMy follow-up was:\n\(followUp)"
        }
        return startPrompt(prompt, in: sessionID)
    }

    public func enqueue(_ rawText: String, attachments: [ChatAttachment] = [], in sessionID: String) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let waitingForConnection = canQueueWhileConnecting(in: sessionID)
        guard chats[sessionID]?.loaded == true || waitingForConnection,
              !text.isEmpty || !attachments.isEmpty else { return false }
        var message = QueuedChatMessage(text: text, attachments: attachments)
        message.waitingForConnection = waitingForConnection
        chats[sessionID]?.queuedMessages.append(message)
        chats[sessionID]?.steeringError = nil
        drainQueue(in: sessionID)
        return true
    }

    public func canQueueWhileConnecting(in sessionID: String) -> Bool {
        makeClient != nil && sessionID == selectedID && chats[sessionID]?.loaded != true
            && chats[sessionID]?.loading == true && (sessionID == target.mainSessionID || listsChat(sessionID))
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
        guard let chat = chats[sessionID], !chat.steering,
              let index = chat.queuedMessages.firstIndex(where: { !chat.queuePaused || $0.confirmedUndelivered }) else { return }
        let message = chat.queuedMessages[index]
        if message.attachments.isEmpty && !message.waitingForConnection {
            if startPrompt(message.text, in: sessionID) { removeQueuedMessage(message.id, in: sessionID) }
            return
        }
        let delivered: @MainActor @Sendable () -> Void = { [weak self] in
            self?.chats[sessionID]?.sendingQueuedID = nil
            self?.removeQueuedMessage(message.id, in: sessionID)
        }
        if startPrompt(message.text, attachments: message.attachments, in: sessionID,
                       onSent: message.attachments.isEmpty ? nil : delivered,
                       onWritten: message.attachments.isEmpty ? delivered : nil) {
            // A reconnect can only replay a queued send that has not been attempted.
            chats[sessionID]?.queuedMessages[index].waitingForConnection = false
            chats[sessionID]?.sendingQueuedID = message.id
        }
    }

    public func submitHermesVoice(_ rawText: String, in sessionID: String) async throws -> String {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client = preparePrompt(text, for: sessionID) else {
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

    private func preparePrompt(_ text: String, photos: [TranscriptPhoto] = [], for sessionID: String) -> ACPClient? {
        guard let client, let chat = chats[sessionID], !text.isEmpty || !photos.isEmpty, chat.loaded, !chat.loading,
              !chat.working, !chat.configuring else { return nil }
        if let index = sessions.firstIndex(where: { $0.id == sessionID && $0.title == "Untitled chat" }) {
            let row = sessions[index]
            sessions[index] = SessionSummary(id: sessionID, title: String((text.isEmpty ? photos.first?.name ?? text : text).prefix(48)), cwd: row.cwd,
                                             nativeSessionKey: row.nativeSessionKey)
        }
        observe(client)
        chats[sessionID]?.transcript.addPrompt(text, photos: photos)
        chats[sessionID]?.submittingPrompt = true
        chats[sessionID]?.turnStartedAt = .now
        recordWorkingState(sessionID)
        chats[sessionID]?.plan = []
        chats[sessionID]?.error = nil
        chats[sessionID]?.steeringError = nil
        chats[sessionID]?.notice = nil
        chats[sessionID]?.replyTimedOut = false
        chats[sessionID]?.uncertainFollowUp = nil
        return client
    }

    private func finishPrompt(_ sessionID: String, from client: ACPClient, advanceQueue: Bool) {
        guard self.client === client else { return }
        prompts[sessionID] = nil
        attachmentDeliveries.removeValue(forKey: sessionID)
        guard var chat = chats[sessionID] else { return }
        chat.sendingQueuedID = nil
        chat.submittingPrompt = false
        chat.sendingAttachmentDraft = false
        chat.stopping = false
        if !chat.working {
            chat.turnStartedAt = nil
            chat.transcript.finishPrompt()
        }
        if !advanceQueue, !chat.queuedMessages.isEmpty { chat.queuePaused = true }
        chats[sessionID] = chat
        recordWorkingState(sessionID)
        drainQueue(in: sessionID)
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
        scheduleIdleExpiration()
        observer = Task { [weak self] in
            for await event in client.events {
                guard let self, self.client === client, !Task.isCancelled else { break }
                if liveEventsDuringLoad[event.sessionID] != nil {
                    // The stream can reach the model before the task awaiting session/load.
                    liveEventsDuringLoad[event.sessionID]?.append(event)
                } else {
                    receiveLive(event)
                }
            }
            guard let self, self.makeClient != nil, self.client === client, !Task.isCancelled else { return }
            self.clearConnection()
        }
    }

    private func scheduleIdleExpiration() {
        idleTask?.cancel()
        idleTask = nil
        idleDeadline = nil
        guard let idleTimeout, client != nil, !connectionInUse, !voiceConnectionInUse else { return }
        let deadline = ContinuousClock.now + idleTimeout
        idleDeadline = deadline
        idleTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            self?.expireIdleConnection()
        }
    }

    private func expireIdleConnection() {
        guard let client, let idleDeadline, ContinuousClock.now >= idleDeadline else { return }
        // Active turns and unanswered approvals must keep their live connection.
        if creatingChat || catalogRefresh != nil || chats.values.contains(where: {
            $0.loading || $0.working || $0.preparingPrompt || $0.steering || $0.configuring || !$0.permissions.isEmpty
        }) {
            scheduleIdleExpiration()
            return
        }
        observer?.cancel()
        clearConnection(expired: true)
        Task { await client.close() }
    }

    private func clearConnection(expired: Bool = false) {
        client = nil
        observer = nil
        scheduleIdleExpiration()
        pendingApprovalSince.removeAll()
        workingChats.removeAll()
        prompts.removeAll()
        attachmentDeliveries.removeAll()
        liveEventsDuringLoad.removeAll()
        newlyCreatedOpenClawKeys.removeAll()
        for id in Array(chats.keys) {
            guard var chat = chats[id] else { continue }
            if chat.loaded {
                chat.connectionLost = true
                if !expired { chat.error = "Connection closed. Reconnect to reopen this chat." }
            } else if chat.loading && chat.error == nil {
                chat.error = ACPError.disconnected.localizedDescription
            }
            chat.queuePaused = !chat.queuedMessages.isEmpty &&
                (chat.queuePaused || chat.working || chat.queuedMessages.contains { !$0.waitingForConnection })
            chat.transcript.finishPrompt()
            chat.loading = false
            chat.loaded = false
            chat.submittingPrompt = false
            chat.sendingAttachmentDraft = false
            chat.agentWorking = false
            chat.turnStartedAt = nil
            chat.steerAdmissionID = nil
            chat.stopping = false
            chat.preparingPrompt = false
            chat.steering = false
            chat.sendingQueuedID = nil
            chat.permissions = []
            chats[id] = chat
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
        chat.provisionalTranscript = nil
        chat.replyTimedOut = false
        for event in opened.events { chat.receive(event, replaying: true) }
        if !chat.replyTimedOut { chat.uncertainFollowUp = nil }
        chat.transcript.restorePhotos(from: photoStore, in: opened.id)
        if chat.agentWorking { chat.transcript.beginObservedTurn() }
        if let options = opened.configOptions { chat.configOptions = options }
        chat.reportedModelName = opened.reportedModelName
        chat.acceptsImages = opened.acceptsImages
        chat.loaded = true
        chat.connectionLost = false
        chats[opened.id] = chat
        recordWorkingState(opened.id)
        recordApprovalState(opened.id)
        for event in liveEventsDuringLoad.removeValue(forKey: opened.id) ?? [] { receiveLive(event) }
        chats[opened.id]?.loading = false
        drainQueue(in: opened.id)
    }
}
