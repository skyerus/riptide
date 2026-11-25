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
    public let sshHostFingerprint: String?
    public private(set) var accountFingerprint: String?

    public init?(kind: RemoteKind, name: String, address: String, workspace: String, mainSessionID: String?,
                 sshHostFingerprint: String? = nil) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        let mainSessionID = mainSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              workspace.hasPrefix("/"), workspace.utf8.count <= 4_096,
              !workspace.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              kind == .codex || mainSessionID?.isEmpty == false else { return nil }
        if let sshHostFingerprint {
            guard kind != .codex, let endpoint = Self.sshEndpoint(address), let pin = SSHHostPin(sshHostFingerprint) else { return nil }
            self.address = endpoint.url.absoluteString
            self.sshHostFingerprint = pin.fingerprint
        } else {
            guard let url = Self.secureURL(address) else { return nil }
            self.address = url.absoluteString
            self.sshHostFingerprint = nil
        }
        id = UUID()
        self.kind = kind
        self.name = name
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

    private static func sshEndpoint(_ address: String) -> (url: URL, host: String, port: Int, username: String)? {
        guard let parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "ssh", let host = parts.host, !host.isEmpty,
              let username = parts.user, username.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$"#, options: .regularExpression) != nil,
              parts.password == nil, parts.query == nil, parts.fragment == nil, parts.path.isEmpty,
              let url = parts.url, (1...65_535).contains(parts.port ?? 22) else { return nil }
        return (url, host, parts.port ?? 22, username)
    }

    public func makeACPClient(credential: String) -> ACPClient? {
        guard kind != .codex, mainSessionID != nil else { return nil }
        if sshHostFingerprint != nil {
            return sshTransport(credential: credential, command: "riptide-acp").map(ACPClient.init(transport:))
        }
        guard let url = Self.secureURL(address), Self.validBearer(credential) else { return nil }
        return ACPClient(transport: RemoteWebSocketTransport(url: url, bearer: credential))
    }

    public func makeHermesDictation(credential: String) -> CodexDictation? {
        guard kind == .hermes else { return nil }
        if sshHostFingerprint != nil {
            return CodexDictation {
                guard let transport = sshTransport(credential: credential, command: "riptide-dictation") else {
                    throw CodexDictationError.unavailable
                }
                return transport
            }
        }
        guard let url = Self.secureURL(address), Self.validBearer(credential) else { return nil }
        return .webSocket(at: url, bearer: credential)
    }

    public var canOpenHermesScreen: Bool { kind == .hermes && sshHostFingerprint != nil }

    public func makeHermesScreenTransport(credential: String) -> (any JSONMessageTransport)? {
        guard canOpenHermesScreen else { return nil }
        return sshTransport(credential: credential, command: "riptide-hermes-screen")
    }

    func safariSSHTransport(credential: String) -> SSHACPTransport? {
        sshTransport(credential: credential, command: "riptide-safari")
    }

    private func sshTransport(credential: String, command: String) -> SSHACPTransport? {
        guard let sshHostFingerprint, let endpoint = Self.sshEndpoint(address), let pin = SSHHostPin(sshHostFingerprint),
              let identity = SSHDeviceIdentity(privateCredential: credential) else { return nil }
        return SSHACPTransport(host: endpoint.host, port: endpoint.port, username: endpoint.username,
                               identity: identity, pin: pin, command: command)
    }
}
