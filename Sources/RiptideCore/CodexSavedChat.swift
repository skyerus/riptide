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
    public private(set) var photos: [TranscriptPhoto] = []
    public var streaming: Bool
    public var phase: Phase?
    public fileprivate(set) var receipt: MessageReceipt?

    init?(_ item: JSON, starting: Bool = false) {
        guard let id = item["id"]?.string else { return nil }
        switch item["type"]?.string {
        case "userMessage":
            role = .user
            var paragraphs: [String] = []
            for block in item["content"]?.array ?? [] {
                switch block["type"]?.string {
                case "localImage":
                    guard let path = block["path"]?.string, path.hasPrefix("/") else {
                        photos.append(.init(name: "Photo", source: .unavailable))
                        continue
                    }
                    let file = URL(fileURLWithPath: path)
                    let filename = file.lastPathComponent
                    let directory = file.deletingLastPathComponent()
                    let parts = filename.split(separator: "-", maxSplits: 1)
                    let stagedByRiptide = directory.deletingLastPathComponent().lastPathComponent == "attachments"
                        && UUID(uuidString: directory.lastPathComponent) != nil
                        && parts.count == 2 && parts[0].allSatisfy(\.isNumber)
                    photos.append(.init(name: stagedByRiptide ? String(parts[1]) : filename,
                                        source: stagedByRiptide ? .codexPath(path) : .unavailable))
                case "image":
                    let url = block["url"]?.string ?? ""
                    let pieces = url.split(separator: ",", maxSplits: 1)
                    let bytes = pieces.count == 2 && pieces[0].hasPrefix("data:image/")
                        && pieces[0].hasSuffix(";base64") && pieces[1].utf8.count <= ChatAttachment.codexByteLimit * 2
                        ? Data(base64Encoded: String(pieces[1])) : nil
                    photos.append(.init(name: "Photo", source: bytes.map(TranscriptPhoto.Source.data) ?? .unavailable))
                default:
                    if let text = block["text"]?.string { paragraphs.append(text) }
                }
            }
            text = paragraphs.joined(separator: "\n")
        case "agentMessage":
            role = .assistant
            text = item["text"]?.string ?? ""
        default:
            return nil
        }
        guard !text.isEmpty || !photos.isEmpty || (starting && role == .assistant) else { return nil }
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

public enum CodexTranscriptEntry: Identifiable, Sendable {
    public enum ID: Hashable, Sendable {
        case message(String)
        case contextCompaction(String)
    }

    case message(CodexChatMessage)
    case contextCompaction(ContextCompaction)

    public var id: ID {
        switch self {
        case .message(let message): .message(message.id)
        case .contextCompaction(let compaction): .contextCompaction(compaction.id)
        }
    }

    var message: CodexChatMessage? {
        guard case .message(let message) = self else { return nil }
        return message
    }
}

public struct CodexTranscriptTurn: Identifiable, Sendable {
    public let id: String
    public private(set) var entries: [CodexTranscriptEntry] = []
    public private(set) var progress = CodexTurnProgress()

    public init(id: String) { self.id = id }

    public var messages: [CodexChatMessage] { entries.compactMap(\.message) }
    public var replyText: String? { Self.replyText(in: messages) }

    public var isCompactingContext: Bool {
        entries.contains {
            guard case .contextCompaction(let compaction) = $0 else { return false }
            return compaction.isRunning
        }
    }

    public func visibleMessages(isActive: Bool) -> [CodexChatMessage] {
        visibleEntries(isActive: isActive).compactMap(\.message)
    }

    public func visibleEntries(isActive: Bool) -> [CodexTranscriptEntry] {
        guard !isActive else { return entries }
        return entries.filter {
            switch $0 {
            case .message(let message): message.phase != .commentary
            case .contextCompaction(let compaction): !compaction.isRunning
            }
        }
    }

    static func replyText(in messages: [CodexChatMessage]) -> String? {
        let replies = messages.lazy.filter { $0.role == .assistant && $0.phase != .commentary && !$0.text.isEmpty }
        return (replies.first { $0.phase == .finalAnswer } ?? replies.first)?.text
    }

    public mutating func upsert(_ message: CodexChatMessage) {
        let index = entries.firstIndex { $0.id == .message(message.id) } ?? entries.endIndex
        var message = message
        if index == entries.endIndex {
            entries.append(.message(message))
        } else {
            if entries[index].message?.receipt == .seen { message.receipt = .seen }
            entries[index] = .message(message)
        }
        if message.role == .assistant, !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for index in entries.indices.prefix(index) {
                guard var prompt = entries[index].message, prompt.receipt == .delivered else { continue }
                prompt.receipt = .seen
                entries[index] = .message(prompt)
            }
        }
    }

    public mutating func upsert(_ compaction: ContextCompaction) {
        if let index = entries.firstIndex(where: { $0.id == .contextCompaction(compaction.id) }),
           case .contextCompaction(let previous) = entries[index] {
            entries[index] = .contextCompaction(previous.merging(compaction))
        } else {
            entries.append(.contextCompaction(compaction))
        }
    }

    public mutating func appendReply(_ text: String, id: String) {
        let current = entries.first { $0.id == .message(id) }?.message
        guard current?.streaming != false else { return }
        var message = current ?? CodexChatMessage(id: id, role: .assistant, text: "", streaming: true)
        message.text += text
        upsert(message)
    }

    public mutating func finishStreaming() {
        for index in entries.indices {
            guard var message = entries[index].message, message.streaming else { continue }
            message.streaming = false
            entries[index] = .message(message)
        }
    }

    public mutating func apply(_ update: CodexWorkUpdate) { progress.apply(update) }
}

public struct CodexChatSnapshot: Sendable {
    public let turns: [CodexTranscriptTurn]
    public let activeTurnID: String?
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
    case turnStarted(String)
    case live(CodexLiveEvent)
    case approval(CodexChatApproval)
    case approvalResolved(UUID)
    case progress(CodexWorkUpdate)
    case configOptions([SessionConfigOption])
    case context(ContextUsage?)
    case issue(String)
}
