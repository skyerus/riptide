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
        public let chatConfirmation: UUID?

        private enum CodingKeys: String, CodingKey {
            case id, url, origin, active
            case chatConfirmation = "chat_confirmation"
        }

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

    private struct PrepareChat: Encodable {
        let operation = "prepare_chat"
        let body: Body

        struct Body: Encodable {
            let id: String
            let token: UUID
        }
    }

    private struct PrepareReply: Decodable {
        let status: Int
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

    public func prepareChatTurn(token: UUID, on relay: SafariSSHRelay, agent: SafariSSHAgent) async throws -> Bool {
        let frame = try JSONEncoder().encode(PrepareChat(body: .init(id: requestID, token: token)))
        let data = try await relay.request(frame, from: agent, timeout: .seconds(2))
        return try JSONDecoder().decode(PrepareReply.self, from: data).status == 200
    }

    public func acceptsConfirmation(_ request: Request, token: UUID, now: Date = .now) -> Bool {
        expires > now && resumeToken == nil && request.id == requestID && request.url == url &&
            request.origin == origin && !request.active && request.chatConfirmation == token
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
