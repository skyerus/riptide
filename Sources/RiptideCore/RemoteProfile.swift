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
    public private(set) var name: String
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

    public mutating func updateDisplayName(_ proposed: String) {
        if let name = Self.validDisplayName(proposed) { self.name = name }
    }

    static func validDisplayName(_ proposed: String) -> String? {
        guard !proposed.unicodeScalars.contains(where: {
            [.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
        }) else { return nil }
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...80).contains(name.unicodeScalars.count) ? name : nil
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

    public func makeACPClient(credential: String,
                              onDisplayName: (@MainActor @Sendable (String) -> Void)? = nil) -> ACPClient? {
        guard kind != .codex, mainSessionID != nil else { return nil }
        if sshHostFingerprint != nil {
            return sshTransport(credential: credential, command: "riptide-acp").map {
                ACPClient(transport: $0, restrictedSSH: true, onDisplayName: onDisplayName)
            }
        }
        guard let url = Self.secureURL(address), Self.validBearer(credential) else { return nil }
        return ACPClient(transport: RemoteWebSocketTransport(url: url, bearer: credential), onDisplayName: onDisplayName)
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

    public var canUseSSHTalk: Bool { kind == .hermes && sshHostFingerprint != nil }

    public func makeHermesSSHTalk(credential: String) -> (any HermesTalkCalling)? {
        guard canUseSSHTalk, SSHDeviceIdentity(privateCredential: credential) != nil else { return nil }
        return HermesSSHTalk {
            sshTransport(credential: credential, command: "riptide-hermes-talk")
        }
    }

    public var canOpenHermesGroups: Bool { kind == .hermes && sshHostFingerprint != nil }

    public func makeHermesGroups(credential: String) -> HermesGroupsClient? {
        guard canOpenHermesGroups else { return nil }
        return HermesGroupsClient(transport: {
            sshTransport(credential: credential, command: "riptide-hermes-groups")
        })
    }

    public var canOpenHermesScreen: Bool { kind == .hermes && sshHostFingerprint != nil }

    public func makeHermesScreenTransport(credential: String) -> (any JSONMessageTransport)? {
        guard canOpenHermesScreen else { return nil }
        return sshTransport(credential: credential, command: "riptide-hermes-screen")
    }

    public func registerHermesNotifications(credential: String, token: String?, environment: String,
                                            policy: AttentionPolicy) async throws {
        guard kind == .hermes, let transport = sshTransport(credential: credential, command: "riptide-attention") else {
            throw URLError(.unsupportedURL)
        }
        struct Registration: Encodable {
            let id: UUID
            let workspace: String
            let token: String?
            let environment: String
            let policy: AttentionPolicy
        }
        struct Request: Encodable {
            let operation = "register"
            let body: Registration
        }
        struct Response: Decodable { let ok: Bool }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(16)) } catch { return }
            await transport.close()
        }
        defer {
            deadline.cancel()
            Task { await transport.close() }
        }
        let body = Registration(id: id, workspace: id.uuidString, token: token, environment: environment, policy: policy)
        try await transport.send(JSONEncoder().encode(Request(body: body)))
        for try await response in transport.incoming {
            guard try JSONDecoder().decode(Response.self, from: response).ok else { break }
            return
        }
        throw URLError(.cannotConnectToHost)
    }

    /// Pair only through this profile's existing SSH endpoint and host-key pin.
    public func authorizeHermesPairing(_ invitation: HermesPairingInvitation, credential: String,
                                       identity: SSHDeviceIdentity) async throws -> RemoteProfile {
        struct Request: Encodable {
            let profile: String
            let publicKey: String
        }
        struct Reply: Decodable {
            let name: String?
            let workspace: String?
            let mainSessionID: String?
            let error: String?
        }
        guard kind == .hermes, let sshHostFingerprint,
              let transport = sshTransport(credential: credential, command: "riptide-pair-hermes") else {
            throw HermesPairingError.unavailable
        }
        let deadline = Task {
            do {
                try await Task.sleep(for: .seconds(30))
                await transport.close()
            } catch {}
        }
        defer {
            deadline.cancel()
            Task { await transport.close() }
        }
        try await transport.send(JSONEncoder().encode(Request(profile: invitation.profile, publicKey: identity.publicKey)))
        for try await data in transport.incoming {
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            if let error = reply.error { throw HermesPairingError.rejected(error) }
            guard let name = reply.name, let workspace = reply.workspace, let id = reply.mainSessionID,
                  let remote = RemoteProfile(kind: .hermes, name: name, address: address,
                                             workspace: workspace, mainSessionID: id,
                                             sshHostFingerprint: sshHostFingerprint) else {
                break
            }
            return remote
        }
        throw HermesPairingError.unavailable
    }

    public func makePrivateFileTransfer(credential: String) -> PrivateFileTransfer? {
        guard sshHostFingerprint != nil, SSHDeviceIdentity(privateCredential: credential) != nil else { return nil }
        return PrivateFileTransfer(destination: name) {
            sshTransport(credential: credential, command: "riptide-private-file")
        }
    }

    private func sshTransport(credential: String, command: String) -> SSHACPTransport? {
        guard let sshHostFingerprint, let endpoint = Self.sshEndpoint(address), let pin = SSHHostPin(sshHostFingerprint),
              let identity = SSHDeviceIdentity(privateCredential: credential) else { return nil }
        return SSHACPTransport(host: endpoint.host, port: endpoint.port, username: endpoint.username,
                               identity: identity, pin: pin, command: command)
    }
}
