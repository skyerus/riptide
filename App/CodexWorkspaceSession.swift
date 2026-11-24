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
    private(set) var messages: [CodexChatMessage] = []
    private(set) var approvals: [CodexChatApproval] = []
    private(set) var responding = Set<UUID>()
    private(set) var ready = false
    private(set) var working = false
    private(set) var stopping = false
    private(set) var sending = false
    private(set) var issue: String?
    private(set) var hasOlderTurns = false
    private(set) var diff: String?
    private(set) var progress = CodexTurnProgress()
    private var assistantReplied = false

    var locator: WorkspaceChatID? { chat.map { .init(workspace: workspaceID, chat: $0.id) } }
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
        working = false
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
        messages = snapshot.messages
        working = snapshot.working
        hasOlderTurns = snapshot.hasOlderTurns
        progress = snapshot.progress
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
        working = false
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

    private func apply(_ event: CodexChatEvent) {
        switch event {
        case .message(let message):
            upsert(message)
            if message.role == .assistant, message.phase != .commentary, !message.text.isEmpty { assistantReplied = true }
        case .turnStarted:
            working = true
            assistantReplied = false
            stopping = false
            diff = nil
            progress = .init()
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
            progress.apply(update)
        case .issue(let message):
            issue = message
        case .live(let update):
            switch update {
            case .assistantDelta(_, let item, let text):
                if let index = messages.firstIndex(where: { $0.id == item }) {
                    if messages[index].streaming { messages[index].text += text }
                    if messages[index].phase != .commentary, !text.isEmpty { assistantReplied = true }
                } else {
                    messages.append(CodexChatMessage(id: item, role: .assistant, text: text, streaming: true))
                    if !text.isEmpty { assistantReplied = true }
                }
            case .assistantCompleted(_, let item, let text):
                upsert(CodexChatMessage(id: item, role: .assistant, text: text, streaming: false))
                if !text.isEmpty { assistantReplied = true }
            case .completed(_, let status):
                working = false
                publishAttention()
                stopping = false
                if status == "completed" { issue = nil }
                if status == "interrupted" { issue = "Turn stopped." }
                for index in messages.indices where messages[index].streaming { messages[index].streaming = false }
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

    private func upsert(_ message: CodexChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }
}
