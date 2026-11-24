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
    }

    public init(id: String, role: ChatRole, text: String, streaming: Bool, phase: Phase? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.streaming = streaming
        self.phase = phase
    }
}

public struct CodexChatSnapshot: Sendable {
    public let messages: [CodexChatMessage]
    public let working: Bool
    public let hasOlderTurns: Bool
    public let progress: CodexTurnProgress
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
    case message(CodexChatMessage)
    case turnStarted
    case live(CodexLiveEvent)
    case approval(CodexChatApproval)
    case approvalResolved(UUID)
    case progress(CodexWorkUpdate)
    case issue(String)
}
