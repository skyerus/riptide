import Foundation

public struct RelayedAttention: Codable, Equatable, Sendable {
    public let workspace: String
    public let chat: String
    public let reason: AttentionReason
    public let eventID: String
    public let observedAt: TimeInterval

    public var locator: WorkspaceChatID { .init(workspace: workspace, chat: chat) }
    public var receipt: String { "\(workspace)/\(chat)/\(eventID)" }
}

public struct AttentionRelay: Sendable {
    public let origin: URL
    private let bearer: String
    private let request: @Sendable (URLRequest) async throws -> Data

    public init?(origin: String, bearer: String) {
        self.init(origin: origin, bearer: bearer, request: NativeVoiceHTTP.request)
    }

    init?(origin: String, bearer: String, request: @escaping @Sendable (URLRequest) async throws -> Data) {
        guard let parts = URLComponents(string: origin.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, ["", "/"].contains(parts.path), let url = parts.url,
              RemoteProfile.validBearer(bearer) else { return nil }
        self.origin = url
        self.bearer = bearer
        self.request = request
    }

    public func presence(workspace: String? = nil) async throws -> DesktopPresence? {
        let query = workspace.map { URLQueryItem(name: "workspace", value: $0) }
        let data = try await send("/v1/presence", query: query)
        return try JSONDecoder().decode(DesktopPresence?.self, from: data)
    }

    public func inbox() async throws -> [RelayedAttention] {
        let data = try await send("/v1/inbox")
        return try JSONDecoder().decode([RelayedAttention].self, from: data).prefix(100).filter {
            let age = Date().timeIntervalSince1970 - $0.observedAt
            return $0.reason != .followUp && age.isFinite && (-5...3_600).contains(age) &&
                (1...160).contains($0.workspace.utf8.count) && (1...240).contains($0.chat.utf8.count) &&
                (1...160).contains($0.eventID.utf8.count)
        }
    }

    public func updateDevice(id: UUID, token: String?, environment: String, policy: AttentionPolicy) async throws {
        guard ["development", "production"].contains(environment) else { throw NativeVoiceError.invalidEndpoint }
        if let token {
            guard (32...256).contains(token.utf8.count), token.count.isMultiple(of: 2),
                  token.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw NativeVoiceError.invalidReply }
        }
        struct Registration: Encodable {
            let id: UUID
            let token: String?
            let environment: String
            let policy: AttentionPolicy
        }
        let body = try JSONEncoder().encode(Registration(id: id, token: token, environment: environment, policy: policy))
        _ = try await send("/v1/devices", body: body)
    }

    private func send(_ path: String, query: URLQueryItem? = nil, body: Data? = nil) async throws -> Data {
        var url = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        url?.path = path
        if let query { url?.queryItems = [query] }
        guard let endpoint = url?.url else { throw NativeVoiceError.invalidEndpoint }
        var outgoing = URLRequest(url: endpoint, timeoutInterval: 5)
        outgoing.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        if let body {
            outgoing.httpMethod = "POST"
            outgoing.httpBody = body
            outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await request(outgoing)
    }
}
