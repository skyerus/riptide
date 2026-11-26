import Foundation

public struct WorkspaceChatID: Hashable, Codable, Sendable {
    public let workspace: String
    public let chat: String

    public init(workspace: String, chat: String) {
        self.workspace = workspace
        self.chat = chat
    }
}

public enum AttentionReason: String, Hashable, Codable, Sendable, CaseIterable {
    case approval, input, reply, followUp

    public var title: String {
        switch self {
        case .approval: "Approval needed"
        case .input: "Waiting for your input"
        case .reply: "Reply ready"
        case .followUp: "Saved for later"
        }
    }
}

public struct WorkspaceAttention: Identifiable, Equatable, Codable, Sendable {
    public let chat: WorkspaceChatID
    public let title: String
    public let reason: AttentionReason
    public let date: Date
    private var replyPreview: String? = nil

    // Reply text is only needed when issuing an alert. Keep it out of the saved Inbox.
    private enum CodingKeys: String, CodingKey { case chat, title, reason, date }

    public struct ID: Hashable, Sendable {
        public let chat: WorkspaceChatID
        public let reason: AttentionReason

        public init(chat: WorkspaceChatID, reason: AttentionReason) {
            self.chat = chat
            self.reason = reason
        }
    }

    public var id: ID { ID(chat: chat, reason: reason) }
    public var notificationBody: String { replyPreview ?? reason.title }

    public init(chat: WorkspaceChatID, title: String, reason: AttentionReason, date: Date = .now,
                replyText: String? = nil) {
        self.chat = chat
        self.title = title
        self.reason = reason
        self.date = date
        if reason == .reply { replyPreview = replyText.flatMap(Self.preview) }
    }

    static func preview(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let content = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            if content.unicodeScalars.count <= 180 { return content }
            return String(content.unicodeScalars.prefix(179)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return nil
    }

    public static func prioritized(_ entries: [Self]) -> [Self] {
        entries.sorted {
            if $0.reason != $1.reason {
                return Self.priority($0.reason) < Self.priority($1.reason)
            }
            if $0.date != $1.date { return $0.date > $1.date }
            if $0.chat.workspace != $1.chat.workspace { return $0.chat.workspace < $1.chat.workspace }
            return $0.chat.chat < $1.chat.chat
        }
    }

    public static func onePerChat(_ entries: [Self]) -> [Self] {
        var seen = Set<WorkspaceChatID>()
        return prioritized(entries).filter { seen.insert($0.chat).inserted }
    }

    private static func priority(_ reason: AttentionReason) -> Int {
        switch reason {
        case .approval: 0
        case .input: 1
        case .reply: 2
        case .followUp: 3
        }
    }
}
