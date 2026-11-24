import Foundation
import Testing
@testable import RiptideCore

@Suite struct SSHPairingTests {
    @Test func onlyPinnedACPEndpointsCanUseSSH() throws {
        let pin = "SHA256:" + Data(repeating: 7, count: 32).base64EncodedString().dropLast()
        let profile = try #require(RemoteProfile(kind: .hermes, name: "Hermes", address: "ssh://agent@example.invalid:2222",
                                                 workspace: "/work", mainSessionID: "main", sshHostFingerprint: pin))
        let decoded = try JSONDecoder().decode(RemoteProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded == profile)
        #expect(CodexLocalEndpoint(remote: profile, bearer: SSHDeviceIdentity().privateCredential) == nil)
        #expect(RemoteProfile(kind: .codex, name: "Codex", address: profile.address,
                             workspace: "/work", mainSessionID: "main", sshHostFingerprint: pin) == nil)
        for invalid in ["ssh://example.invalid", "ssh://agent:password@example.invalid", "ssh://agent@example.invalid/run",
                        "ssh://agent@example.invalid:0", "ssh://agent@example.invalid?token=abc", "ws://agent@example.invalid"] {
            #expect(RemoteProfile(kind: .hermes, name: "Hermes", address: invalid,
                                 workspace: "/work", mainSessionID: "main", sshHostFingerprint: pin) == nil)
        }
        #expect(RemoteProfile(kind: .hermes, name: "Hermes", address: profile.address,
                             workspace: "/work", mainSessionID: "main", sshHostFingerprint: "trust-on-first-use") == nil)
    }

    @Test func deviceIdentityRestoresWithoutSharingItsPrivateKey() throws {
        let identity = SSHDeviceIdentity()
        let restored = try #require(SSHDeviceIdentity(privateCredential: identity.privateCredential))
        #expect(restored.publicKey == identity.publicKey)
        #expect(identity.publicKey.hasPrefix("ssh-ed25519 "))
        #expect(!identity.publicKey.contains(identity.privateCredential))
    }
}
