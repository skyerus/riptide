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
    private(set) var issue: String?
    private(set) var hasOlderTurns = false
    private(set) var diff: String?
    private var assistantReplied = false
    private var unscopedTurnID: String?
    private var lastTurnStart: (id: String, date: Date)?

    var locator: WorkspaceChatID? { chat.map { .init(workspace: workspaceID, chat: $0.id) } }
    var working: Bool { activeTurnID != nil }
    var activeTurnStartedAt: Date? { working ? lastTurnStart?.date : nil }
    var progress: CodexTurnProgress {
        if let activeTurnID { return turns.last { $0.id == activeTurnID }?.progress ?? .init() }
        return turns.last?.progress ?? .init()
    }
    var needsConnection: Bool { working || sending || !approvals.isEmpty || !ready && listener != nil }

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
        approvals = []
        responding = []
        publishAttention()
        if let old { Task { await old.close() } }
    }

    func send(_ text: String) async -> Bool {
        guard let client, ready, !sending, !stopping, !text.isEmpty else { return false }
        sending = true
        issue = nil
        defer { sending = false }
        do {
            try await client.sendToSavedChat(text)
            return true
        } catch {
            issue = error.localizedDescription
            return false
        }
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
        setActiveTurn(snapshot.activeTurnID, startedAt: snapshot.activeTurnStartedAt)
        unscopedTurnID = nil
        hasOlderTurns = snapshot.hasOlderTurns
        assistantReplied = snapshot.messages.contains { $0.streaming && $0.role == .assistant &&
            $0.phase != .commentary && !$0.text.isEmpty }
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

    private func setActiveTurn(_ id: String?, startedAt: Date?) {
        if let id {
            let previousStart = lastTurnStart?.id == id ? lastTurnStart?.date : nil
            let now = Date.now
            lastTurnStart = (id, min(startedAt ?? previousStart ?? now, now))
        }
        activeTurnID = id
    }

    private func apply(_ event: CodexChatEvent) {
        switch event {
        case .message(let message, let turnID):
            turns[turnIndex(for: turnID)].upsert(message)
            if message.role == .assistant, message.phase != .commentary, !message.text.isEmpty { assistantReplied = true }
        case .turnStarted(let id, let startedAt):
            let alreadyActive = activeTurnID == id
            setActiveTurn(id, startedAt: startedAt)
            guard !alreadyActive else { return }
            assistantReplied = false
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
        case .issue(let message):
            issue = message
        case .live(let update):
            switch update {
            case .assistantDelta(let turn, let item, let text):
                if turns[turnIndex(for: turn)].appendReply(text, id: item) { assistantReplied = true }
            case .assistantCompleted(let turn, let item, let text):
                turns[turnIndex(for: turn)].upsert(.init(id: item, role: .assistant, text: text, streaming: false))
                if !text.isEmpty { assistantReplied = true }
            case .completed(let turn, let status):
                activeTurnID = nil
                lastTurnStart = nil
                publishAttention()
                stopping = false
                if status == "completed" { issue = nil }
                if status == "interrupted" { issue = "Turn stopped." }
                if let index = turns.lastIndex(where: { $0.id == turn }) { turns[index].finishStreaming() }
                if status == "completed", assistantReplied, let locator, let chat {
                    workspace?.receivedCodexReply(locator, title: chat.title)
                }
                workspace?.pruneCodexSessions()
            case .diff(_, let patch):
                diff = patch.isEmpty ? nil : patch
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
