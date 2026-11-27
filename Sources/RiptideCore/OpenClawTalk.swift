import CryptoKit
import Foundation

public struct OpenClawDeviceIdentity: Sendable {
    private let key: Curve25519.Signing.PrivateKey

    public init() { key = Curve25519.Signing.PrivateKey() }
    public init(rawRepresentation: Data) throws { key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation) }
    public var rawRepresentation: Data { key.rawRepresentation }

    func connectParams(nonce: String, timestamp: Int, token: String) throws -> JSON {
        let publicKey = key.publicKey.rawRepresentation
        let id = SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
        let scope = "operator.talk"
        let payload = ["v3", id, "cli", "cli", "operator", scope, String(timestamp), token, nonce, "ios", "iphone"]
            .joined(separator: "|")
        let signature = try key.signature(for: Data(payload.utf8))
        return [
            "minProtocol": .integer(3), "maxProtocol": .integer(4),
            "client": ["id": "cli", "displayName": "Riptide", "version": "0.1", "platform": "ios",
                       "deviceFamily": "iphone", "mode": "cli"],
            "role": "operator", "scopes": .array([.string(scope)]),
            "auth": ["token": .string(token)],
            "device": ["id": .string(id), "publicKey": .string(Self.base64url(publicKey)),
                       "signature": .string(Self.base64url(signature)), "signedAt": .integer(timestamp),
                       "nonce": .string(nonce)]
        ]
    }

    private static func base64url(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public actor OpenClawTalk {
    public nonisolated let events: AsyncThrowingStream<String, any Error>
    private let output: AsyncThrowingStream<String, any Error>.Continuation
    private let transport: any JSONMessageTransport
    private let profile: NativeVoiceProfile
    private let token: String
    private let identity: OpenClawDeviceIdentity
    private let exchange: @Sendable (URLRequest) async throws -> Data
    private let voiceID = UUID().uuidString.lowercased()
    private var sessionKey: String?
    private var reader: Task<Void, Never>?
    private var challenge: JSON?
    private var pending: [String: CheckedContinuation<JSON, any Error>] = [:]
    private var closed = false
    private var transcript = VoiceTranscript()

    public init?(profile: NativeVoiceProfile, token: String, identity: OpenClawDeviceIdentity) {
        guard profile.kind == .openClaw, RemoteProfile.validBearer(token),
              let url = RemoteProfile.secureURL(profile.address) else { return nil }
        self.init(profile: profile, token: token, identity: identity,
                  transport: RemoteWebSocketTransport(url: url), exchange: NativeVoiceHTTP.request)
    }

    init(profile: NativeVoiceProfile, token: String, identity: OpenClawDeviceIdentity,
         transport: any JSONMessageTransport, exchange: @escaping @Sendable (URLRequest) async throws -> Data) {
        self.profile = profile
        self.token = token
        self.identity = identity
        self.transport = transport
        self.exchange = exchange
        (events, output) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingNewest(2))
    }

    deinit { reader?.cancel(); output.finish() }

    public func pair() async throws -> String {
        defer { shutdown() }
        let hello = try await connect()
        guard let deviceToken = hello["auth"]?["deviceToken"]?.string,
              RemoteProfile.validBearer(deviceToken) else { throw NativeVoiceError.authentication }
        return deviceToken
    }

    public func start(offer: String, sessionKey: String) async throws {
        guard sessionKey.hasPrefix("agent:"), sessionKey.utf8.count <= 512 else { throw NativeVoiceError.invalidReply }
        let offer = try NativeVoiceHTTP.checkedSDP(offer)
        _ = try await connect()
        let result = try await call("talk.client.create", [
            "sessionKey": .string(sessionKey), "voiceSessionId": .string(voiceID),
            "mode": "realtime", "transport": "webrtc", "brain": "agent-consult",
            "capabilities": .array(["gateway-control-v1"])
        ])
        guard result["voiceSessionId"]?.string == voiceID else { throw NativeVoiceError.invalidReply }
        self.sessionKey = sessionKey
        guard result["clientControl"]?["owner"] == "gateway",
              result["transport"] == "webrtc", result["offerUrl"] == "/plugins/openai/realtime/calls",
              let secret = result["clientSecret"]?.string, RemoteProfile.validBearer(secret),
              let url = profile.httpURL(path: "/plugins/openai/realtime/calls") else { throw NativeVoiceError.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(offer.utf8)
        let answer = try await exchange(request)
        guard !closed else { throw NativeVoiceError.expired }
        output.yield(try NativeVoiceHTTP.checkedSDP(String(data: answer, encoding: .utf8)))
    }

    @discardableResult
    public func end() async -> [VoiceTranscriptLine] {
        if let sessionKey, !closed {
            self.sessionKey = nil
            _ = try? await call("talk.client.close", ["sessionKey": .string(sessionKey), "voiceSessionId": .string(voiceID)])
        }
        shutdown()
        return transcript.lines
    }

    private func connect() async throws -> JSON {
        guard reader == nil, !closed else { throw NativeVoiceError.expired }
        reader = Task { [weak self, transport] in
            do {
                for try await frame in transport.incoming {
                    try Task.checkCancellation()
                    await self?.receive(frame)
                }
                await self?.shutdown()
            } catch {
                await self?.shutdown(error)
            }
        }
        for _ in 0..<80 where challenge == nil && !closed { try await Task.sleep(for: .milliseconds(100)) }
        guard let challenge, let nonce = challenge["nonce"]?.string, !nonce.isEmpty, nonce.utf8.count <= 256,
              !nonce.contains("|"), let timestamp = challenge["ts"]?.integer, timestamp >= 0 else {
            throw NativeVoiceError.authentication
        }
        let hello = try await call("connect", identity.connectParams(nonce: nonce, timestamp: timestamp, token: token))
        guard hello["type"] == "hello-ok",
              hello["features"]?["methods"]?.array?.contains("talk.client.create") == true else {
            throw NativeVoiceError.unavailable
        }
        return hello
    }

    private func call(_ method: String, _ params: JSON) async throws -> JSON {
        try Task.checkCancellation()
        guard !closed else { throw NativeVoiceError.expired }
        let id = UUID().uuidString
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            await self?.fail(id, NativeVoiceError.gatewayUnavailable)
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                Task {
                    guard pending[id] != nil else { return }
                    do {
                        let request: JSON = ["type": "req", "id": .string(id), "method": .string(method), "params": params]
                        try await transport.send(JSONEncoder().encode(request))
                    } catch {
                        fail(id, error)
                    }
                }
            }
        } onCancel: {
            Task { await self.fail(id, CancellationError()) }
        }
    }

    private func receive(_ data: Data) {
        guard let frame = try? JSONDecoder().decode(JSON.self, from: data) else { return }
        if frame["type"] == "event" {
            if frame["event"] == "connect.challenge", challenge == nil { challenge = frame["payload"] }
            if frame["event"] == "talk.event", let payload = frame["payload"],
               payload["voiceSessionId"]?.string == voiceID, let event = payload["talkEvent"] {
                if event["type"] == "session.closed" {
                    sessionKey = nil
                    shutdown()
                } else {
                    receiveTranscript(event)
                }
            }
        } else if frame["type"] == "res", let id = frame["id"]?.string,
                  let request = pending.removeValue(forKey: id) {
            if frame["ok"] == .boolean(true), let result = frame["payload"] {
                request.resume(returning: result)
            } else if let details = frame["error"]?["details"], details["code"] == "PAIRING_REQUIRED",
                      let pairing = details["requestId"]?.string,
                      (1...80).contains(pairing.utf8.count),
                      pairing.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }) {
                request.resume(throwing: NativeVoiceError.openClawPairingRequired(pairing))
            } else {
                request.resume(throwing: NativeVoiceError.gatewayUnavailable)
            }
        }
    }

    private func receiveTranscript(_ event: JSON) {
        guard let type = event["type"]?.string, let payload = event["payload"],
              let text = payload["text"]?.string, let turnID = event["turnId"]?.string else { return }
        let role: ChatRole
        switch type {
        case "output.text.delta", "output.text.done":
            role = .assistant
        case "transcript.delta", "transcript.done":
            guard let reportedRole = payload["role"]?.string.flatMap(ChatRole.init(rawValue:)) else { return }
            role = reportedRole
        default:
            return
        }
        transcript.append(role: role, text: text, itemID: turnID, final: type.hasSuffix(".done"))
    }

    private func fail(_ id: String, _ error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func shutdown(_ error: any Error = NativeVoiceError.expired) {
        guard !closed else { return }
        closed = true
        reader?.cancel()
        reader = nil
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
        output.finish()
    }
}
