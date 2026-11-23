import Foundation
import Observation

public struct ChatEntry: Identifiable, Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case message(ChatRole, String)
        case tool(ToolActivity)
    }

    public let id = UUID()
    public fileprivate(set) var content: Content
}

public struct Transcript: Equatable, Sendable {
    public private(set) var entries: [ChatEntry] = []
    private var messageIndices: [String: Int] = [:]
    private var toolIndices: [String: Int] = [:]
    private var openMessage: Int?

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
        entries.append(ChatEntry(content: .message(.user, text)))
    }

    public mutating func apply(_ event: ACPEvent) {
        switch event {
        case .message(_, let messageID, let role, let text):
            let index = messageID.flatMap { messageIndices[$0] } ?? (messageID == nil ? openMessage : nil)
            if let index, case .message(let existingRole, let existing) = entries[index].content, existingRole == role {
                entries[index].content = .message(role, existing + text)
            } else {
                openMessage = entries.count
                if let messageID { messageIndices[messageID] = entries.count }
                entries.append(ChatEntry(content: .message(role, text)))
            }
        case .tool(_, let activity):
            if let index = toolIndices[activity.id], case .tool(let previous) = entries[index].content {
                entries[index].content = .tool(ToolActivity(id: activity.id,
                    title: activity.title ?? previous.title, status: activity.status ?? previous.status))
            } else {
                openMessage = nil
                toolIndices[activity.id] = entries.count
                entries.append(ChatEntry(content: .tool(activity)))
            }
        case .permission, .permissionClosed, .configOptions, .context:
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
    private var newlyCreatedOpenClawKeys: [String: String] = [:]
    @ObservationIgnored private var client: ACPClient?
    @ObservationIgnored private var makeClient: (@Sendable () -> ACPClient)?
    @ObservationIgnored private var observer: Task<Void, Never>?

    public struct ChatState {
        public fileprivate(set) var transcript = Transcript()
        public fileprivate(set) var permissions: [PermissionRequest] = []
        public fileprivate(set) var configOptions: [SessionConfigOption] = []
        public fileprivate(set) var context: ContextUsage?
        public fileprivate(set) var configuring = false
        public fileprivate(set) var configError: String?
        public fileprivate(set) var loading = false
        public fileprivate(set) var loaded = false
        public fileprivate(set) var working = false
        public fileprivate(set) var stopping = false
        public fileprivate(set) var error: String?
        public fileprivate(set) var notice: String?

        fileprivate mutating func receive(_ event: ACPEvent) {
            switch event {
            case .message(_, _, .user, _) where working:
                break
            case .message, .tool:
                transcript.apply(event)
            case .configOptions(_, let options):
                configOptions = options
            case .context(_, let usage):
                context = usage
            case .permission(let request):
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
    public var mainActivity: String? {
        guard let main = chats[target.mainSessionID] else { return nil }
        if !main.permissions.isEmpty { return "Needs approval" }
        if main.working { return "Working" }
        return nil
    }
    public var title: String {
        selectedID == target.mainSessionID ? "Main Chat" :
            sessions.first { $0.id == selectedID }?.title ?? "Untitled chat"
    }

    public func selectMain() { selectedID = target.mainSessionID }

    public func showMain() async { await open(target.mainSessionID) }

    public func open(_ sessionID: String) async {
        if makeClient != nil, sessionID != target.mainSessionID,
           !sessions.contains(where: { $0.id == sessionID && $0.cwd == target.cwd }) { return }
        selectedID = sessionID
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
            if makeClient != nil && !chats.values.contains(where: \.loaded) {
                await client.close()
            }
        }
    }

    public func refreshSessions() async {
        guard !refreshingList else { return }
        guard let client else { listError = selected.error; return }
        refreshingList = true
        listError = nil
        defer { refreshingList = false }
        do {
            let listed = try await client.sessions()
            sessions = makeClient == nil ? listed : listed.filter { $0.cwd == target.cwd }
        }
        catch { if !Task.isCancelled { listError = error.localizedDescription } }
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

    public func submit(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID = selectedID
        guard let client = preparePrompt(text, for: sessionID) else { return }
        Task {
            defer { finishPrompt(sessionID, from: client) }
            do {
                switch try await client.prompt(text, sessionID: sessionID) {
                case "end_turn": break
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
        do { return try await client.promptForVoice(text, sessionID: sessionID) }
        catch {
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
        chats[sessionID]?.error = nil
        chats[sessionID]?.notice = nil
        return client
    }

    private func finishPrompt(_ sessionID: String, from client: ACPClient) {
        guard self.client === client else { return }
        chats[sessionID]?.working = false
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
            }
            guard let self, self.makeClient != nil, self.client === client, !Task.isCancelled else { return }
            self.client = nil
            self.newlyCreatedOpenClawKeys.removeAll()
            self.observer = nil
            for id in Array(self.chats.keys) {
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
        chat.loaded = true
        chats[opened.id] = chat
    }
}
