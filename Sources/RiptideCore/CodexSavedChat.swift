import Foundation

public struct CodexChatSummary: Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let status: CodexChatStatus
    public let updatedAt: Date?

    public init(id: String, title: String) {
        self.id = id
        self.title = title
        status = .unknown
        updatedAt = nil
    }

    init?(_ thread: JSON) {
        guard let id = thread["id"]?.string, !id.isEmpty else { return nil }
        self.id = id
        title = [thread["name"]?.string, thread["preview"]?.string].compactMap { $0 }
            .first { !$0.isEmpty }.map { String($0.prefix(100)) } ?? "Untitled chat"
        status = CodexChatStatus(thread["status"])
        updatedAt = thread["updatedAt"]?.integer.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

public enum CodexChatStatus: Hashable, Sendable {
    case unknown, idle, active, approval, input

    init(_ status: JSON?) {
        switch status?["type"]?.string {
        case "idle": self = .idle
        case "active":
            let flags = status?["activeFlags"]?.array ?? []
            if flags.contains("waitingOnApproval") { self = .approval }
            else if flags.contains("waitingOnUserInput") { self = .input }
            else { self = .active }
        default: self = .unknown
        }
    }
}

public struct CodexChatMessage: Equatable, Identifiable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case commentary
        case partialAnswer = "partial_answer"
        case finalAnswer = "final_answer"
    }

    public let id: String
    public let role: ChatRole
    public var text: String
    public var streaming: Bool
    public var phase: Phase?
    public fileprivate(set) var receipt: MessageReceipt?

    init?(_ item: JSON, starting: Bool = false) {
        guard let id = item["id"]?.string else { return nil }
        switch item["type"]?.string {
        case "userMessage":
            role = .user
            text = item["content"]?.array?.compactMap { $0["text"]?.string }.joined(separator: "\n") ?? ""
        case "agentMessage":
            role = .assistant
            text = item["text"]?.string ?? ""
        default:
            return nil
        }
        guard !text.isEmpty || (starting && role == .assistant) else { return nil }
        self.id = id
        streaming = starting
        phase = item["phase"]?.string.flatMap(Phase.init(rawValue:))
        receipt = role == .user ? .delivered : nil
    }

    public init(id: String, role: ChatRole, text: String, streaming: Bool, phase: Phase? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.streaming = streaming
        self.phase = phase
        receipt = role == .user ? .delivered : nil
    }
}

public struct CodexTranscriptTurn: Identifiable, Sendable {
    public let id: String
    public private(set) var messages: [CodexChatMessage] = []
    public private(set) var progress = CodexTurnProgress()

    public init(id: String) { self.id = id }

    public mutating func upsert(_ message: CodexChatMessage) {
        let index: Int
        if let existing = messages.firstIndex(where: { $0.id == message.id }) {
            index = existing
            let receipt = messages[index].receipt
            messages[index] = message
            if receipt == .seen { messages[index].receipt = receipt }
        } else {
            index = messages.count
            messages.append(message)
        }
        if message.role == .assistant, !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for prompt in messages.indices.prefix(index) where messages[prompt].receipt == .delivered {
                messages[prompt].receipt = .seen
            }
        }
    }

    public mutating func appendReply(_ text: String, id: String) -> Bool {
        let current = messages.first { $0.id == id }
        guard current?.streaming != false else { return false }
        var message = current ?? CodexChatMessage(id: id, role: .assistant, text: "", streaming: true)
        message.text += text
        upsert(message)
        return message.phase != .commentary && !text.isEmpty
    }

    public mutating func finishStreaming() {
        for index in messages.indices where messages[index].streaming { messages[index].streaming = false }
    }

    public mutating func apply(_ update: CodexWorkUpdate) { progress.apply(update) }
}

public struct CodexChatSnapshot: Sendable {
    public let turns: [CodexTranscriptTurn]
    public let activeTurnID: String?
    public let activeTurnStartedAt: Date?
    public let hasOlderTurns: Bool

    public var messages: [CodexChatMessage] { turns.flatMap(\.messages) }
    public var working: Bool { activeTurnID != nil }
    public var progress: CodexTurnProgress { turns.first { $0.id == activeTurnID }?.progress ?? .init() }
}

public struct CodexChatApproval: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let command: String?
    public let cwd: String?
    public let reason: String?
    public let canAllow: Bool
    public let canDecline: Bool
    public let isInput: Bool
    public let questions: [CodexInputQuestion]?
}

public struct CodexInputQuestion: Equatable, Identifiable, Sendable {
    public struct Option: Equatable, Identifiable, Sendable {
        public let label: String
        public let detail: String
        public var id: String { label }
    }

    public let id: String
    public let header: String
    public let prompt: String
    public let options: [Option]
    public let acceptsFreeText: Bool

    init?(_ value: JSON) {
        guard value["isSecret"] != .boolean(true), let id = value["id"]?.string, (1...240).contains(id.utf8.count),
              let header = value["header"]?.string, let prompt = value["question"]?.string,
              (1...2_400).contains(prompt.utf8.count) else { return nil }
        self.id = id
        self.header = String(header.prefix(120))
        self.prompt = prompt
        let rows = value["options"]?.array ?? []
        guard rows.count <= 12 else { return nil }
        options = rows.compactMap { option in
            guard let label = option["label"]?.string, (1...320).contains(label.utf8.count) else { return nil }
            return Option(label: label, detail: String((option["description"]?.string ?? "").prefix(600)))
        }
        guard rows.count == options.count, Set(options.map(\.label)).count == options.count else { return nil }
        acceptsFreeText = options.isEmpty || value["isOther"] == .boolean(true)
    }

    func accepts(_ text: String) -> Bool {
        if options.contains(where: { $0.label == text }) { return true }
        return acceptsFreeText && (1...4_000).contains(text.utf8.count) && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum CodexChatEvent: Sendable {
    case message(CodexChatMessage, turnID: String?)
    case turnStarted(String, startedAt: Date?)
    case live(CodexLiveEvent)
    case approval(CodexChatApproval)
    case approvalResolved(UUID)
    case progress(CodexWorkUpdate)
    case issue(String)
}
