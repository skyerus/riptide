import Foundation

/// Consent is written by the app. The separate binding receipt is written by Safari
/// once the extension has associated the launch with a top-level tab.
public struct SafariChatHandoff: Codable, Equatable, Sendable {
    private struct BindingReceipt: Codable {
        let token: UUID
    }

    public struct Request: Decodable, Sendable {
        public let id: String
        public let url: URL
        public let origin: String
        public let active: Bool

        private struct Response: Decodable {
            let status: Int
            let body: Body
        }

        private struct Body: Decodable {
            let handoff: Request?
        }

        public static func pending(on relay: SafariSSHRelay, agent: SafariSSHAgent) async throws -> Request? {
            let frame = Data(#"{"operation":"state","body":{}}"#.utf8)
            let data = try await relay.request(frame, from: agent, timeout: .seconds(2))
            let reply = try JSONDecoder().decode(Response.self, from: data)
            guard reply.status == 200, let handoff = reply.body.handoff, !handoff.active else { return nil }
            return handoff
        }
    }

    public let requestID: String
    public let agentID: UUID
    public let chatID: String
    public let url: URL
    public let origin: String
    public let openToken: UUID
    public let expires: Date
    public private(set) var resumeToken: UUID?
    private var resumeExpires: Date?

    public init(request: Request, agentID: UUID, chatID: String, now: Date = .now) {
        requestID = request.id
        self.agentID = agentID
        self.chatID = chatID
        url = request.url
        origin = request.origin
        openToken = UUID()
        expires = now.addingTimeInterval(300)
    }

    public static func isConfirmation(_ message: String) -> Bool {
        let normalized = message.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        return ["i've signed in", "i have signed in", "i'm signed in", "i am signed in",
                "i've logged in", "i have logged in", "i'm logged in", "i am logged in"].contains(normalized)
    }

    public var launchURL: URL? { markedURL(openToken) }
    public var resumeURL: URL? { resumeToken.flatMap(markedURL) }

    private func markedURL(_ token: UUID) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.host != nil,
              parts.user == nil, parts.password == nil else { return nil }
        let fragment = parts.percentEncodedFragment ?? ""
        parts.percentEncodedFragment = "riptide-handoff=\(token.uuidString)&\(fragment)"
        return parts.url
    }

    public func tokenPurpose(_ token: UUID, origin: String, now: Date = .now) -> String? {
        guard self.origin == origin, expires > now else { return nil }
        if token == openToken, resumeToken == nil { return "open" }
        if token == resumeToken, let resumeExpires, resumeExpires > now { return "resume" }
        return nil
    }

    public mutating func approve(now: Date = .now) {
        resumeToken = UUID()
        resumeExpires = now.addingTimeInterval(30)
    }

    public static func load(from store: SafariSSHKeychain) throws -> Self? {
        try store.read("chat-handoff")
    }

    public func save(to store: SafariSSHKeychain) throws {
        try store.write(self, account: "chat-handoff")
    }

    public func recordBinding(in store: SafariSSHKeychain) throws {
        try store.write(BindingReceipt(token: openToken), account: "chat-tab-binding")
    }

    public func isBound(in store: SafariSSHKeychain) throws -> Bool {
        let receipt: BindingReceipt? = try store.read("chat-tab-binding")
        return receipt?.token == openToken
    }
}
