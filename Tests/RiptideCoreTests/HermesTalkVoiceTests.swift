import Foundation
import Testing
@testable import RiptideCore

struct HermesTalkVoiceTests {
    @Test func startsSubscriptionAudioOnlyForTheExactACPChatAndClosesBothBindings() async throws {
        let wire = TalkWire(.ready)
        let client = try makeClient(wire)
        let answer = try await client.answer(offer: "v=0\r\n", sessionID: "my-chat")
        #expect(answer == "v=0 answer\r\n")
        #expect(try await client.poll() == .working)
        #expect(try await client.poll() == .result)
        await client.end()
        await client.end()
        #expect(await wire.calls == [
            "/status", "/targets", "/native/attach", "/status", "/live/session",
            "/live/events", "/live/events", "/live/close", "/close"
        ])
    }

    @Test func APIBillingRefusesBeforeBindingAndNeverDialsAFallback() async throws {
        let wire = TalkWire(.paid)
        let client = try makeClient(wire)
        await #expect(throws: HermesTalkVoiceError.subscriptionRequired) {
            try await client.answer(offer: "v=0\r\n", sessionID: "my-chat")
        }
        #expect(await wire.calls == ["/status"])
    }

    @Test func refusesWhenTheHostChangesBillingAfterBindingButBeforeTheOffer() async throws {
        let wire = TalkWire(.changesBilling)
        let client = try makeClient(wire)
        await #expect(throws: HermesTalkVoiceError.subscriptionRequired) {
            try await client.answer(offer: "v=0\r\n", sessionID: "my-chat")
        }
        #expect(await wire.calls == ["/status", "/targets", "/native/attach", "/status", "/close"])
    }

    @Test func refusesOtherChatsAndProfilesWithoutOpeningAudio() async throws {
        for scenario in [TalkWire.Scenario.wrongCatalog, .wrongAttach] {
            let wire = TalkWire(scenario)
            let client = try makeClient(wire)
            await #expect(throws: HermesTalkVoiceError.wrongChat) {
                try await client.answer(offer: "v=0\r\n", sessionID: "my-chat")
            }
            let calls = await wire.calls
            #expect(calls == (scenario == .wrongCatalog
                ? ["/status", "/targets"] : ["/status", "/targets", "/native/attach", "/close"]))
        }
    }

    @Test func olderPairingsKeepTheirExplicitRouteAndNeverUseTalkCredentials() throws {
        let data = Data(#"{"kind":"hermes","address":"https://host.example","hermesProfile":"sandbox"}"#.utf8)
        let profile = try JSONDecoder().decode(NativeVoiceProfile.self, from: data)
        #expect(profile.selectedHermesRoute == .builtIn)
        #expect(HermesTalkVoice(profile: profile, dashboardToken: TalkWire.dashboardToken) == nil)
        let subscription = try #require(NativeVoiceProfile(kind: .hermes, address: "https://host.example",
                                                             hermesRoute: .talkSubscription))
        #expect(HermesLiveVoice(profile: subscription, token: TalkWire.dashboardToken) == nil)
    }

    private func makeClient(_ wire: TalkWire) throws -> HermesTalkVoice {
        let profile = try #require(NativeVoiceProfile(kind: .hermes, address: "https://host.example:8443",
                                                       hermesProfile: "sandbox", hermesRoute: .talkSubscription))
        let request: @Sendable (URLRequest) async throws -> Data = { request in try await wire.reply(request) }
        return try #require(HermesTalkVoice(profile: profile, dashboardToken: TalkWire.dashboardToken,
                                          talkToken: TalkWire.talkToken, request: request))
    }
}

private actor TalkWire {
    enum Scenario { case ready, paid, changesBilling, wrongCatalog, wrongAttach }
    static let dashboardToken = String(repeating: "d", count: 40)
    static let talkToken = String(repeating: "t", count: 40)
    private let scenario: Scenario
    private(set) var calls: [String] = []
    private var tab: String?

    init(_ scenario: Scenario) { self.scenario = scenario }

    func reply(_ request: URLRequest) throws -> Data {
        let url = try #require(request.url)
        #expect(url.scheme == "https")
        #expect(url.host == "host.example")
        #expect(url.port == 8443)
        #expect(url.query == nil)
        #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == Self.dashboardToken)
        #expect(request.value(forHTTPHeaderField: "X-Talk-Token") == Self.talkToken)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let prefix = "/api/plugins/hermes-talk"
        #expect(url.path.hasPrefix(prefix))
        let route = String(url.path.dropFirst(prefix.count))
        calls.append(route)
        let body: JSON
        if let data = request.httpBody { body = try JSONDecoder().decode(JSON.self, from: data) }
        else { body = [:] }
        #expect(request.httpMethod == (route == "/status" ? "GET" : "POST"))
        if ["/live/session", "/live/events", "/live/close", "/close"].contains(route) {
            #expect(body["connection_id"] == "connection-1")
            #expect(body["generation"] == .integer(14))
        }
        if ["/live/events", "/live/close"].contains(route) { #expect(body["binding_id"] == "binding-1") }
        let result: JSON
        switch route {
        case "/status":
            let paid = scenario == .paid || (scenario == .changesBilling && calls.count > 1)
            result = ["ok": .boolean(true), "configured": .boolean(true), "voiceMode": "live",
                      "source": paid ? "env" : "codex-oauth", "liveAuth": paid ? "api" : "subscription",
                      "model": paid ? "gpt-live-1" : "gpt-live-1-codex", "taskContinuity": ["supported": .boolean(true)]]
        case "/targets":
            #expect(body["profile"] == "sandbox")
            #expect(body["peer_id"] == "local")
            #expect(body["session_id"] == "my-chat")
            tab = try #require(body["tab_id"]?.string)
            result = ["ok": .boolean(true), "targets": .array([
                ["profile": "sandbox", "peer_id": "other-host", "session_id": "my-chat", "target_id": "wrong-peer"],
                ["profile": scenario == .wrongCatalog ? "another-profile" : "sandbox",
                 "peer_id": "local", "session_id": "my-chat", "target_id": "own-target"]
            ])]
        case "/native/attach":
            let tab = try #require(tab)
            #expect(body["surface"] == "dashboard")
            #expect(body["input_mode"] == "typed")
            #expect(body["tab_id"] == .string(tab))
            #expect(body["target_id"] == "own-target")
            result = ["ok": .boolean(true), "input_mode": "typed", "task": [
                "tab_id": .string(tab), "target_id": "own-target", "profile": "sandbox",
                "session_id": scenario == .wrongAttach ? "other-chat" : "my-chat", "peer_id": "local",
                "connection_id": "connection-1", "generation": .integer(14)
            ], "selection": ["state": "activated", "target_id": "own-target"]]
        case "/live/session":
            #expect(body["sdp"] == "v=0\r\n")
            #expect(body["history"] == nil)
            result = ["ok": .boolean(true), "binding_id": "binding-1", "sdp": "v=0 answer\r\n"]
        case "/live/events":
            let cursor = try #require(body["after"]?.integer)
            result = ["ok": .boolean(true), "cursor": .integer(cursor + 1), "events": .array([
                ["sequence": .integer(cursor + 1), "type": cursor == 0 ? "operation" : "result", "pending": .boolean(true)]
            ])]
        case "/live/close", "/close":
            result = ["ok": .boolean(true)]
        default:
            Issue.record("Unexpected route: \(route)")
            result = [:]
        }
        return try JSONEncoder().encode(result)
    }
}
