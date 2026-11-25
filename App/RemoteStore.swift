import Foundation
import Observation
import RiptideCore
import Security

@MainActor
@Observable
final class RemoteStore {
    private(set) var profiles: [RemoteProfile]
    private var voices: [UUID: NativeVoiceProfile]
    private let defaults: UserDefaults
    private let metadataKey = "riptide.remote-profiles.v1"
    private let voiceKey = "riptide.native-voice-profiles.v1"
    private let safariPairings: SafariSSHKeychain?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        safariPairings = defaults === UserDefaults.standard ? SafariSSHKeychain() : nil
        profiles = defaults.data(forKey: metadataKey)
            .flatMap { try? JSONDecoder().decode([RemoteProfile].self, from: $0) } ?? []
        voices = defaults.data(forKey: voiceKey)
            .flatMap { try? JSONDecoder().decode([UUID: NativeVoiceProfile].self, from: $0) } ?? [:]
        try? shareSafariPairings(profiles)
    }

    private func shareSafariPairings(_ profiles: [RemoteProfile]) throws {
        guard let safariPairings else { return }
        let agents = profiles.compactMap { profile -> SafariSSHAgent? in
            guard profile.sshHostFingerprint != nil, let credential = KeychainToken.read(profile.id) else { return nil }
            return SafariSSHAgent(profile: profile, credential: credential)
        }
        try safariPairings.replace(with: agents)
    }

    func pair(_ profile: RemoteProfile, credential: String) async throws {
        var paired = profile
        if let endpoint = CodexLocalEndpoint(remote: profile, bearer: credential) {
            let client = endpoint.makeClient()
            do {
                _ = try await client.listSavedChats()
                paired.bindCodexAccount(try await client.pairingFingerprint())
                await client.close()
            } catch {
                await client.close()
                throw error
            }
        } else if let client = profile.makeACPClient(credential: credential) {
            do {
                let chats = try await client.sessions()
                guard chats.contains(where: { $0.id == profile.mainSessionID && $0.cwd == profile.workspace }) else {
                    throw PairingFailure.mainNotFound
                }
                guard try await client.canLoadSessions() else { throw ACPError.historyUnavailable }
                await client.close()
            } catch {
                await client.close()
                throw error
            }
        } else {
            throw PairingFailure.invalid
        }
        try Task.checkCancellation()
        let metadata = try JSONEncoder().encode(profiles + [paired])
        try KeychainToken.save(credential, for: profile.id)
        defaults.set(metadata, forKey: metadataKey)
        profiles.append(paired)
        if paired.sshHostFingerprint != nil { try? shareSafariPairings(profiles) }
    }

    func bearer(for profile: RemoteProfile) -> String? { KeychainToken.read(profile.id) }

    func voice(for profile: RemoteProfile) -> NativeVoiceProfile? { voices[profile.id] }

    func pairVoice(_ voice: NativeVoiceProfile, token: String, talkToken: String? = nil, for profile: RemoteProfile) async throws {
        guard profile.kind == voice.kind, profiles.contains(profile), RemoteProfile.validBearer(token),
              let chatHost = URL(string: profile.address)?.host?.lowercased(),
              URL(string: voice.address)?.host?.lowercased() == chatHost else {
            throw PairingFailure.invalid
        }
        let admittedToken: String
        switch voice.kind {
        case .hermes:
            switch voice.selectedHermesRoute {
            case .talkSubscription:
                guard let client = HermesTalkVoice(profile: voice, dashboardToken: token, talkToken: talkToken) else {
                    throw PairingFailure.invalid
                }
                try await client.checkAvailability()
            case .builtIn:
                guard let client = HermesLiveVoice(profile: voice, token: token) else { throw PairingFailure.invalid }
                try await client.checkAvailability()
            }
            admittedToken = token
        case .openClaw:
            let identity = try openClawIdentity(for: profile.id, create: true)
            guard let client = OpenClawTalk(profile: voice, token: token, identity: identity) else {
                throw PairingFailure.invalid
            }
            admittedToken = try await client.pair()
        case .codex:
            throw PairingFailure.invalid
        }
        try Task.checkCancellation()
        guard profiles.contains(profile) else { throw PairingFailure.invalid }
        var updated = voices
        updated[profile.id] = voice
        let metadata = try JSONEncoder().encode(updated)
        try KeychainToken.save(admittedToken, for: profile.id, purpose: "voice")
        if voice.kind == .hermes, voice.selectedHermesRoute == .talkSubscription, let talkToken {
            try KeychainToken.save(talkToken, for: profile.id, purpose: "hermes-talk")
        } else {
            try KeychainToken.remove(profile.id, purpose: "hermes-talk")
        }
        defaults.set(metadata, forKey: voiceKey)
        voices = updated
    }

    func voiceLink(for profile: RemoteProfile) throws -> NativeVoiceLink {
        guard let voice = voices[profile.id], voice.kind == profile.kind,
              let token = KeychainToken.read(profile.id, purpose: "voice") else { throw PairingFailure.keychain }
        if voice.kind == .hermes, voice.selectedHermesRoute == .talkSubscription {
            let talkToken = KeychainToken.read(profile.id, purpose: "hermes-talk")
            guard let client = HermesTalkVoice(profile: voice, dashboardToken: token, talkToken: talkToken) else {
                throw PairingFailure.invalid
            }
            return .hermesTalk(client)
        }
        if let hermes = HermesLiveVoice(profile: voice, token: token) { return .hermes(hermes) }
        let identity = try openClawIdentity(for: profile.id, create: false)
        if let claw = OpenClawTalk(profile: voice, token: token, identity: identity) { return .openClaw(claw) }
        throw PairingFailure.invalid
    }

    private func openClawIdentity(for id: UUID, create: Bool) throws -> OpenClawDeviceIdentity {
        if let stored = KeychainToken.read(id, purpose: "openclaw-device"),
           let bytes = Data(base64Encoded: stored) {
            return try OpenClawDeviceIdentity(rawRepresentation: bytes)
        }
        guard create else { throw PairingFailure.keychain }
        let identity = OpenClawDeviceIdentity()
        try KeychainToken.save(identity.rawRepresentation.base64EncodedString(), for: id, purpose: "openclaw-device")
        return identity
    }

    func forget(_ profile: RemoteProfile) throws {
        let remaining = profiles.filter { $0.id != profile.id }
        let metadata = try JSONEncoder().encode(remaining)
        if profile.sshHostFingerprint != nil { try shareSafariPairings(remaining) }
        try KeychainToken.remove(profile.id)
        try KeychainToken.remove(profile.id, purpose: "voice")
        try KeychainToken.remove(profile.id, purpose: "hermes-talk")
        try KeychainToken.remove(profile.id, purpose: "openclaw-device")
        voices.removeValue(forKey: profile.id)
        defaults.set(try JSONEncoder().encode(voices), forKey: voiceKey)
        defaults.set(metadata, forKey: metadataKey)
        profiles = remaining
    }
}

enum NativeVoiceLink {
    case hermes(HermesLiveVoice)
    case hermesTalk(HermesTalkVoice)
    case openClaw(OpenClawTalk)
}

enum PairingFailure: LocalizedError {
    case invalid, mainNotFound, keychain

    var errorDescription: String? {
        switch self {
        case .invalid: "Check the endpoint, workspace path, and pairing details."
        case .mainNotFound: "The agent did not list that main chat in the paired workspace."
        case .keychain: "Riptide couldn’t access this remote’s credential in Keychain."
        }
    }
}

enum KeychainToken {
    private static func query(_ id: UUID, purpose: String?) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "app.riptide.client.remote" + (purpose.map { ".\($0)" } ?? ""),
         kSecAttrAccount as String: id.uuidString,
         kSecAttrSynchronizable as String: false]
    }

    static func save(_ token: String, for id: UUID, purpose: String? = nil) throws {
        let key = query(id, purpose: purpose)
        var attributes = key
        let bytes = Data(token.utf8)
        attributes[kSecValueData as String] = bytes
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard SecItemUpdate(key as CFDictionary, [kSecValueData as String: bytes] as CFDictionary) == errSecSuccess else {
                throw PairingFailure.keychain
            }
        } else if status != errSecSuccess {
            throw PairingFailure.keychain
        }
    }

    static func read(_ id: UUID, purpose: String? = nil) -> String? {
        var attributes = query(id, purpose: purpose)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(_ id: UUID, purpose: String? = nil) throws {
        let status = SecItemDelete(query(id, purpose: purpose) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PairingFailure.keychain }
    }
}
