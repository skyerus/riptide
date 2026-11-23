import Foundation

public struct CodexChatSummary: Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String

    init?(_ thread: JSON) {
        guard let id = thread["id"]?.string, !id.isEmpty else { return nil }
        self.id = id
        title = [thread["name"]?.string, thread["preview"]?.string].compactMap { $0 }
            .first { !$0.isEmpty }.map { String($0.prefix(100)) } ?? "Untitled chat"
    }
}

public struct CodexChatMessage: Equatable, Identifiable, Sendable {
    public let id: String
    public let role: ChatRole
    public var text: String
    public var streaming: Bool

    init?(_ item: JSON) {
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
        guard !text.isEmpty else { return nil }
        self.id = id
        streaming = false
    }

    public init(id: String, role: ChatRole, text: String, streaming: Bool) {
        self.id = id
        self.role = role
        self.text = text
        self.streaming = streaming
    }
}

public struct CodexChatSnapshot: Sendable {
    public let messages: [CodexChatMessage]
    public let working: Bool
    public let hasOlderTurns: Bool
}

public struct CodexChatApproval: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let command: String?
    public let cwd: String?
    public let reason: String?
    public let canAllow: Bool
    public let canDecline: Bool
}

public enum CodexChatEvent: Sendable {
    case message(CodexChatMessage)
    case turnStarted
    case live(CodexLiveEvent)
    case approval(CodexChatApproval)
    case approvalResolved(UUID)
}
