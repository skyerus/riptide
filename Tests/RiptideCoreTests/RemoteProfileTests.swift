import Testing
@testable import RiptideCore

struct RemoteProfileTests {
    @Test func pairingRequiresTLSWithoutEmbeddedCredentials() {
        for address in ["ws://example.net/ws", "https://example.net/ws", "wss://username:secret@example.net",
                        "wss://example.net/?token=secret", "wss://example.net/ws#token", "wss:///ws"] {
            #expect(RemoteProfile.secureURL(address) == nil)
        }
        #expect(RemoteProfile.secureURL("wss://example.net/agent")?.path == "/agent")
        #expect(!RemoteProfile.validBearer(String(repeating: "a", count: 32) + "\r\nHeader: value"))
    }

    @Test func acpRemotesRequireAnExplicitExistingMainID() {
        for backend in [RemoteKind.hermes, .openClaw] {
            #expect(RemoteProfile(kind: backend, name: "Remote", address: "wss://example.net", workspace: "/proj",
                                  mainSessionID: nil) == nil)
            #expect(RemoteProfile(kind: backend, name: "Remote", address: "wss://example.net", workspace: "/proj",
                                  mainSessionID: "existing")?.mainSessionID == "existing")
        }
    }
}
