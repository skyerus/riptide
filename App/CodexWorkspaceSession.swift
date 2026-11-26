import Observation
import RiptideCore
import SwiftUI

@MainActor @Observable
final class CodexWorkspaceSession {
    private let endpoint: CodexLocalEndpoint
    let workspaceID: String
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private weak var workspace: WorkspaceState?
    private(set) var chat: CodexChatSummary?
    private(set) var client: CodexLiveClient?
    private(set) var turns: [CodexTranscriptTurn] = []
    private(set) var activeTurnID: String?
    private(set) var approvals: [CodexChatApproval] = []
    private(set) var responding = Set<UUID>()
    private(set) var ready = false
    private(set) var stopping = false
    private(set) var sending = false
    private(set) var configOptions: [SessionConfigOption] = []
    private(set) var context: ContextUsage?
    private(set) var configuring = false
    private(set) var configError: String?
    private(set) var queuedMessages: [QueuedChatMessage] = []
    private(set) var sendingQueuedID: UUID?
    private(set) var queuePaused = false
    private(set) var issue: String?
    private(set) var sendIssue: String?
    private(set) var hasOlderTurns = false
    private(set) var diff: String?
    private var lastCompletedTurnID: String?
    private var unscopedTurnID: String?

    var locator: WorkspaceChatID? { chat.map { .init(workspace: workspaceID, chat: $0.id) } }
    var working: Bool { activeTurnID != nil }
    var progress: CodexTurnProgress {
        if let activeTurnID { return turns.last { $0.id == activeTurnID }?.progress ?? .init() }
        return turns.last?.progress ?? .init()
    }
    var needsConnection: Bool {
        working || sending || !queuedMessages.isEmpty || !approvals.isEmpty || !ready && listener != nil
    }

    init(endpoint: CodexLocalEndpoint, chat: CodexChatSummary?, workspaceID: String, workspace: WorkspaceState) {
        self.endpoint = endpoint
        self.chat = chat
        self.workspaceID = workspaceID
        self.workspace = workspace
    }

    deinit { listener?.cancel() }

    func start() {
        guard listener == nil else { return }
        let peer = endpoint.makeClient()
        let existing = chat
        client = peer
        issue = nil
        listener = Task { [weak self] in
            do {
                if let existing {
                    let snapshot = try await peer.openSavedChat(existing.id)
                    try Task.checkCancellation()
                    self?.setSnapshot(snapshot, peer: peer)
                } else {
                    let created = try await peer.createSavedChat()
                    try Task.checkCancellation()
                    self?.setChat(created, peer: peer)
                }
                self?.connected(peer)
                let discovery = Task { await peer.discoverSavedChatConfiguration() }
                defer { discovery.cancel() }
                for try await event in peer.chatEvents {
                    guard let self, !Task.isCancelled, self.client === peer else { break }
                    self.apply(event)
                }
                self?.finished(peer, message: Task.isCancelled ? nil : "Connection closed.")
            } catch {
                self?.finished(peer, message: Task.isCancelled ? nil : error.localizedDescription)
            }
            await peer.close()
        }
    }

    func detach() {
        let old = client
        listener?.cancel()
        listener = nil
        client = nil
        ready = false
        activeTurnID = nil
        stopping = false
        sending = false
        clearConfiguration()
        sendingQueuedID = nil
        queuePaused = !queuedMessages.isEmpty
        approvals = []
        responding = []
        publishAttention()
        if let old { Task { await old.close() } }
    }

    func enqueue(_ text: String, attachments: [ChatAttachment] = []) {
        sendIssue = nil
        queuedMessages.append(QueuedChatMessage(text: text, attachments: attachments))
        drainQueue()
    }

    func removeQueuedMessage(_ id: UUID) {
        guard id != sendingQueuedID else { return }
        queuedMessages.removeAll { $0.id == id }
        if queuedMessages.isEmpty { queuePaused = false }
    }

    func resumeQueue() {
        queuePaused = false
        drainQueue()
    }

    private func drainQueue() {
        guard ready, !working, !sending, !stopping, !configuring, !queuePaused, !queuedMessages.isEmpty else { return }
        Task {
            guard !working, !queuePaused, let message = queuedMessages.first else { return }
            await send(message.text, attachments: message.attachments, queuedID: message.id)
        }
    }

    @discardableResult
    func send(_ text: String, attachments: [ChatAttachment] = [], queuedID: UUID? = nil) async -> CodexMessageDelivery? {
        guard let client, ready, !sending, !stopping, !configuring, !text.isEmpty || !attachments.isEmpty else { return nil }
        sending = true
        sendingQueuedID = queuedID
        sendIssue = nil
        defer {
            if self.client === client {
                sending = false
                sendingQueuedID = nil
                drainQueue()
            }
        }
        do {
            let previousTurnID = activeTurnID
            let delivery = try await client.sendToSavedChat(text, attachments: attachments, startOnly: queuedID != nil)
            guard self.client === client else { return nil }
            if case .started(let id) = delivery, activeTurnID == nil || activeTurnID == previousTurnID,
               lastCompletedTurnID != id {
                apply(.turnStarted(id))
            }
            if let queuedID { queuedMessages.removeAll { $0.id == queuedID } }
            return delivery
        } catch {
            guard self.client === client else { return nil }
            if queuedID != nil { queuePaused = true }
            sendIssue = error.localizedDescription
            return nil
        }
    }

    func setConfigOption(_ id: String, value: String) async -> Bool {
        guard let client, ready, !working, !sending, !configuring else { return false }
        configuring = true
        configError = nil
        defer {
            if self.client === client {
                configuring = false
                drainQueue()
            }
        }
        do {
            let options = try await client.setSavedChatConfigOption(id, value: value)
            guard self.client === client else { return false }
            configOptions = options
            return options.contains { $0.id == id && $0.currentValue == value }
        } catch {
            if self.client === client { configError = error.localizedDescription }
            return false
        }
    }

    private func clearConfiguration() {
        configOptions = []
        context = nil
        configuring = false
        configError = nil
    }

    func answer(_ approval: CodexChatApproval, allow: Bool) {
        respond(to: approval) { try await $0.answer(approval, allow: allow) }
    }

    func answerInput(_ input: CodexChatApproval, values: [String: String]) {
        respond(to: input) { try await $0.answerInput(input, values: values) }
    }

    func interrupt() async {
        guard let client, working, !stopping else { return }
        stopping = true
        do { try await client.interruptSavedTurn() }
        catch {
            stopping = false
            issue = error.localizedDescription
        }
    }

    private func setSnapshot(_ snapshot: CodexChatSnapshot, peer: CodexLiveClient) {
        guard client === peer else { return }
        turns = snapshot.turns
        activeTurnID = snapshot.activeTurnID
        unscopedTurnID = nil
        hasOlderTurns = snapshot.hasOlderTurns
    }

    private func setChat(_ summary: CodexChatSummary, peer: CodexLiveClient) {
        guard client === peer else { return }
        chat = summary
        workspace?.retain(self)
    }

    private func connected(_ peer: CodexLiveClient) {
        guard client === peer else { return }
        ready = true
        publishAttention()
    }

    private func finished(_ peer: CodexLiveClient, message: String?) {
        guard client === peer else { return }
        listener = nil
        client = nil
        ready = false
        activeTurnID = nil
        stopping = false
        clearConfiguration()
        sending = false
        sendingQueuedID = nil
        queuePaused = !queuedMessages.isEmpty
        approvals = []
        responding = []
        issue = message
        publishAttention()
    }

    private func respond(to request: CodexChatApproval, using action: @escaping @Sendable (CodexLiveClient) async throws -> Void) {
        guard let client, ready, responding.insert(request.id).inserted else { return }
        Task {
            do { try await action(client) }
            catch {
                guard self.client === client else { return }
                issue = error.localizedDescription
                responding.remove(request.id)
            }
        }
    }

    private func publishAttention() {
        guard let locator else { return }
        let reason: AttentionReason? = approvals.contains { !$0.isInput } ? .approval : approvals.isEmpty ? nil : .input
        workspace?.setCodexAttention(reason, chat: locator, connected: ready)
        workspace?.setCodexRunning(working, chat: locator)
    }

    private func apply(_ event: CodexChatEvent) {
        switch event {
        case .message(let message, let turnID):
            turns[turnIndex(for: turnID)].upsert(message)
        case .turnStarted(let id):
            guard activeTurnID != id else { return }
            activeTurnID = id
            stopping = false
            diff = nil
            issue = nil
            publishAttention()
        case .approval(let approval):
            approvals.append(approval)
            publishAttention()
        case .approvalResolved(let id):
            approvals.removeAll { $0.id == id }
            responding.remove(id)
            publishAttention()
        case .progress(let update):
            if let activeTurnID { turns[turnIndex(for: activeTurnID)].apply(update) }
        case .configOptions(let options):
            configOptions = options
        case .context(let usage):
            context = usage
        case .issue(let message):
            issue = message
        case .live(let update):
            switch update {
            case .assistantDelta(let turn, let item, let text):
                turns[turnIndex(for: turn)].appendReply(text, id: item)
            case .assistantCompleted(let turn, let message):
                turns[turnIndex(for: turn)].upsert(message)
            case .completed(let turn, let status):
                lastCompletedTurnID = turn
                activeTurnID = nil
                publishAttention()
                stopping = false
                if status == "completed" { issue = nil }
                if status == "interrupted" { issue = "Turn stopped." }
                if status != "completed", !queuedMessages.isEmpty { queuePaused = true }
                if let index = turns.lastIndex(where: { $0.id == turn }) {
                    turns[index].finishStreaming()
                    if status == "completed", let reply = turns[index].replyText, let locator, let chat {
                        workspace?.receivedCodexReply(locator, title: chat.title, reply: reply)
                    }
                }
                workspace?.pruneCodexSessions()
                drainQueue()
            case .diff(_, let patch):
                diff = patch.isEmpty ? nil : patch
            case .context(_, let usage):
                context = usage
            case .output:
                break
            }
        }
    }

    private func turnIndex(for reportedID: String?) -> Int {
        let id: String
        if let reportedID {
            id = reportedID
        } else if let unscopedTurnID, turns.last?.id == unscopedTurnID {
            id = unscopedTurnID
        } else {
            id = UUID().uuidString
            unscopedTurnID = id
        }
        if let index = turns.lastIndex(where: { $0.id == id }) { return index }
        turns.append(CodexTranscriptTurn(id: id))
        return turns.index(before: turns.endIndex)
    }
}
