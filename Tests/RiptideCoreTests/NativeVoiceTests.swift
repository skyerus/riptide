import CryptoKit
import Foundation
import Testing
@testable import RiptideCore

struct NativeVoiceTests {
    @Test func hermesUsesNativeHTTPAndSeedsOnlyBoundChatHistory() async throws {
        let profile = try #require(NativeVoiceProfile(kind: .hermes, address: "https://hermes.example", hermesProfile: "test"))
        let token = String(repeating: "h", count: 48)
        let exchange: @Sendable (URLRequest) async throws -> Data = { request in
            #expect(request.url?.host == "hermes.example")
            #expect(request.url?.query == "profile=test")
            #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == token)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            if request.url?.path == "/api/audio/voice-live/status" {
                #expect(request.httpMethod == "GET")
                return Data(#"{"ok":true,"mode":"gpt-live","available":true}"#.utf8)
            }
            #expect(request.url?.path == "/api/audio/voice-live/session")
            #expect(request.httpMethod == "POST")
            let payload = try JSONDecoder().decode(JSON.self, from: #require(request.httpBody))
            #expect(payload["sdp"] == "v=0\r\n")
            #expect(payload["history"]?.array?.count == 2)
            #expect(payload["history"]?.array?.last?["content"]?.array?.first?["type"] == "output_text")
            return Data(#"{"ok":true,"transport":{"type":"webrtc","sdp":"v=0 answer"}}"#.utf8)
        }
        let client = try #require(HermesLiveVoice(profile: profile, token: token, request: exchange))
        try await client.checkAvailability()
        #expect(try await client.answer(offer: "v=0\r\n", history: [
            HermesVoiceLine(role: .user, text: "Question"), HermesVoiceLine(role: .assistant, text: "Answer")
        ]) == "v=0 answer")
    }

    @Test func hermesDelegationUsesNewestSpokenInputOnlyAndDoesNotReplayEvents() throws {
        var events = HermesLiveEvents()
        func frame(_ value: String) -> Data { Data(value.utf8) }
        let old = frame(#"{"type":"session.input_transcript.delta","delta":"Earlier question","end_ms":200}"#)
        let provider = frame(#"{"type":"session.output_transcript.delta","delta":"Do not send me as a prompt."}"#)
        let new = frame(#"{"type":"session.input_transcript.delta","delta":"Check the status","start_ms":3000}"#)
        let request = frame(#"{"type":"session.delegation.created","delegation":{"id":"ask-1"}}"#)
        #expect(events.accept(old, listening: true) == nil)
        #expect(events.accept(provider, listening: true) == nil)
        #expect(events.accept(new, listening: false) == nil)
        #expect(events.accept(new, listening: true) == nil)
        #expect(events.accept(request, listening: true) == .delegation(id: "ask-1", text: "Check the status"))
        #expect(events.accept(request, listening: true) == nil)
        let commentary = try #require(HermesLiveEvents.commentary("It finished.", delegationID: "ask-1").first)
        let message = try JSONDecoder().decode(JSON.self, from: commentary)
        #expect(message["type"] == "session.commentary.append")
        #expect(message["delegation_id"] == "ask-1")
    }

    @Test func hermesWillNotStartABilledVoiceSessionAfterHostSwitchesModes() async throws {
        let profile = try #require(NativeVoiceProfile(kind: .hermes, address: "https://hermes.example"))
        let request: @Sendable (URLRequest) async throws -> Data = { request in
            #expect(request.url?.path == "/api/audio/voice-live/status")
            #expect(request.httpMethod == "GET")
            return Data(#"{"ok":true,"mode":"chained","available":true}"#.utf8)
        }
        let client = try #require(HermesLiveVoice(profile: profile, token: String(repeating: "h", count: 48), request: request))
        await #expect(throws: NativeVoiceError.unavailable) {
            try await client.answer(offer: "v=0\r\n", history: [])
        }
    }

    @Test func openClawOwnsVoiceAndHangsUpOnlyTheBoundChat() async throws {
        let profile = try #require(NativeVoiceProfile(kind: .openClaw, address: "wss://claw.example:7443"))
        let identity = OpenClawDeviceIdentity()
        let token = String(repeating: "d", count: 48)
        let broker = String(repeating: "b", count: 48)
        let wire = try VoiceTestTransport { request in
            let id = try #require(request["id"])
            let params = try #require(request["params"])
            let result: JSON
            switch request["method"]?.string {
            case "connect":
                #expect(params["auth"]?["token"]?.string == token)
                #expect(params["scopes"] == .array(["operator.talk"]))
                #expect(params["device"]?["nonce"] == "pending")
                let key = try Curve25519.Signing.PrivateKey(rawRepresentation: identity.rawRepresentation).publicKey
                let fingerprint = SHA256.hash(data: key.rawRepresentation).map { String(format: "%02x", $0) }.joined()
                let payload = "v3|\(fingerprint)|cli|cli|operator|operator.talk|10|\(token)|pending|ios|iphone"
                let signature = try #require(params["device"]?["signature"]?.string)
                    .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=="
                let signatureBytes = try #require(Data(base64Encoded: signature))
                #expect(key.isValidSignature(signatureBytes, for: Data(payload.utf8)))
                result = ["type": "hello-ok", "features": ["methods": .array(["talk.client.create"])]]
            case "talk.client.create":
                #expect(params["sessionKey"] == "agent:main:work")
                #expect(params["capabilities"] == .array(["gateway-control-v1"]))
                result = ["transport": "webrtc", "offerUrl": "/plugins/openai/realtime/calls",
                          "clientControl": ["owner": "gateway"], "clientSecret": .string(broker),
                          "voiceSessionId": try #require(params["voiceSessionId"])]
            case "talk.client.close":
                #expect(params["sessionKey"] == "agent:main:work")
                let voiceID = try #require(params["voiceSessionId"]?.string)
                #expect(!voiceID.isEmpty)
                result = [:]
            default:
                Issue.record("Unexpected OpenClaw method")
                result = [:]
            }
            return ["type": "res", "id": id, "ok": .boolean(true), "payload": result]
        }
        let client = OpenClawTalk(profile: profile, token: token, identity: identity, transport: wire) { request in
            #expect(request.url?.absoluteString == "https://claw.example:7443/plugins/openai/realtime/calls")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(broker)")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/sdp")
            #expect(request.httpBody == Data("v=0\r\n".utf8))
            return Data("v=0 answer".utf8)
        }
        try await client.start(offer: "v=0\r\n", sessionKey: "agent:main:work")
        var events = client.events.makeAsyncIterator()
        #expect(try await events.next() == "v=0 answer")
        await client.end()
    }

    @Test func voiceEndpointCannotDowngradeTLSOrHideCredentialsInURL() {
        #expect(NativeVoiceProfile(kind: .hermes, address: "http://host.example") == nil)
        #expect(NativeVoiceProfile(kind: .hermes, address: "https://user:password@host.example") == nil)
        #expect(NativeVoiceProfile(kind: .openClaw, address: "wss://host.example?token=bad") == nil)
        #expect(NativeVoiceProfile(kind: .openClaw, address: "wss://host.example") != nil)
    }
}

private final class VoiceTestTransport: JSONMessageTransport {
    let incoming: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let script: @Sendable (JSON) throws -> JSON

    init(script: @escaping @Sendable (JSON) throws -> JSON) throws {
        self.script = script
        (incoming, continuation) = AsyncThrowingStream.makeStream()
        continuation.yield(try JSONEncoder().encode(["type": "event", "event": "connect.challenge",
                                                   "payload": ["nonce": "pending", "ts": .integer(10)]] as JSON))
    }

    func send(_ data: Data) async throws {
        let request = try JSONDecoder().decode(JSON.self, from: data)
        continuation.yield(try JSONEncoder().encode(script(request)))
    }
}
