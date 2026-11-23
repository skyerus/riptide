import Foundation

public enum RemoteKind: String, Codable, CaseIterable, Sendable {
    case codex, openClaw, hermes

    public var name: String {
        switch self {
        case .codex: "Codex"
        case .openClaw: "OpenClaw"
        case .hermes: "Hermes"
        }
    }
}

public struct RemoteProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: RemoteKind
    public let name: String
    public let address: String
    public let workspace: String
    public let mainSessionID: String?
    public private(set) var accountFingerprint: String?

    public init?(kind: RemoteKind, name: String, address: String, workspace: String, mainSessionID: String?) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        let mainSessionID = mainSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              let url = Self.secureURL(address),
              workspace.hasPrefix("/"), workspace.utf8.count <= 4_096,
              !workspace.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              kind == .codex || mainSessionID?.isEmpty == false else { return nil }
        id = UUID()
        self.kind = kind
        self.name = name
        self.address = url.absoluteString
        self.workspace = workspace
        self.mainSessionID = kind == .codex ? nil : mainSessionID
    }

    public mutating func bindCodexAccount(_ fingerprint: String) {
        guard kind == .codex else { return }
        accountFingerprint = fingerprint
    }

    public static func secureURL(_ address: String) -> URL? {
        let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: normalized), parts.scheme == "wss",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let url = parts.url else { return nil }
        return url
    }

    public static func validBearer(_ value: String) -> Bool {
        (32...4_096).contains(value.utf8.count) &&
            value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.~+/=".contains($0)) }
    }

    public func makeACPClient(bearer: String) -> ACPClient? {
        guard kind != .codex, let url = Self.secureURL(address), Self.validBearer(bearer),
              mainSessionID != nil else { return nil }
        return ACPClient(transport: RemoteWebSocketTransport(url: url, bearer: bearer))
    }
}
