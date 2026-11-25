import Foundation
import Security

public struct SafariSSHAgent: Codable, Equatable, Sendable {
    public let profile: RemoteProfile
    private let credential: String

    public init?(profile: RemoteProfile, credential: String) {
        guard profile.sshHostFingerprint != nil, SSHDeviceIdentity(privateCredential: credential) != nil else { return nil }
        self.profile = profile
        self.credential = credential
    }

    fileprivate var transport: SSHACPTransport? {
        profile.safariSSHTransport(credential: credential)
    }
}

public enum SafariSSHError: LocalizedError {
    case keychain, pairing, unavailable

    public var errorDescription: String? {
        switch self {
        case .keychain: "Riptide’s shared SSH pairings couldn’t be read from Keychain."
        case .pairing: "This agent is no longer paired in Riptide."
        case .unavailable: "The paired agent’s Safari relay disconnected. Check the connection and try again."
        }
    }
}

public struct SafariSSHKeychain {
    private let accessGroup: String

    public init?() {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "RiptideSafariKeychainGroup") as? String,
              !group.isEmpty, !group.contains("$") else { return nil }
        accessGroup = group
    }

    private var record: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.riptide.client.safari.ssh",
            kSecAttrAccount as String: "paired-agents",
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: false
        ]
    }

    public func load() throws -> [SafariSSHAgent] {
        var query = record
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = value as? Data else { throw SafariSSHError.keychain }
        return try JSONDecoder().decode([SafariSSHAgent].self, from: data)
    }

    public func replace(with agents: [SafariSSHAgent]) throws {
        let key = record
        if agents.isEmpty {
            let status = SecItemDelete(key as CFDictionary)
            guard status == errSecItemNotFound || status == errSecSuccess else { throw SafariSSHError.keychain }
            return
        }
        let data = try JSONEncoder().encode(agents)
        var attributes = key
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = [kSecValueData as String: data] as CFDictionary
            guard SecItemUpdate(key as CFDictionary, update) == errSecSuccess else { throw SafariSSHError.keychain }
        } else {
            guard status == errSecSuccess else { throw SafariSSHError.keychain }
        }
    }
}

public actor SafariSSHRelay {
    private struct Connection {
        let agent: SafariSSHAgent
        let transport: SSHACPTransport
        var reader: AsyncThrowingStream<Data, any Error>.Iterator
        var lastUse = ContinuousClock.now
    }

    private var connection: Connection?
    private var previousWork: Task<Void, Never>?

    public init() {}

    public func request(_ frame: Data, from agent: SafariSSHAgent) async throws -> Data {
        // The forced command returns one reply per frame. Serialize requests even when Safari
        // polls the tab while its popup updates or the user takes back control.
        let previous = previousWork
        let work = Task {
            await previous?.value
            return try await exchange(frame, agent: agent)
        }
        previousWork = Task { _ = try? await work.value }
        return try await work.value
    }

    private func exchange(_ frame: Data, agent: SafariSSHAgent) async throws -> Data {
        var link: Connection
        if let cached = connection, cached.agent == agent,
           cached.lastUse.duration(to: .now) < .seconds(35) {
            link = cached
        } else {
            guard let transport = agent.transport else { throw SafariSSHError.pairing }
            link = Connection(agent: agent, transport: transport, reader: transport.incoming.makeAsyncIterator())
        }
        connection = nil
        let transport = link.transport
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(16)) } catch { return }
            await transport.close()
        }
        defer { deadline.cancel() }
        try await transport.send(frame)
        guard let reply = try await link.reader.next(isolation: self) else { throw SafariSSHError.unavailable }
        link.lastUse = .now
        connection = link
        return reply
    }
}
