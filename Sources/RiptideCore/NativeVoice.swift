import Foundation

public enum HermesVoiceRoute: String, Codable, CaseIterable, Identifiable, Sendable {
    case talkSubscription, builtIn

    public var id: Self { self }

    public var title: String {
        switch self {
        case .talkSubscription: "Talk · ChatGPT subscription"
        case .builtIn: "Built-in GPT-Live · API billing"
        }
    }
}

public struct NativeVoiceProfile: Codable, Equatable, Sendable {
    public let kind: RemoteKind
    public let address: String
    public let hermesProfile: String?
    private let hermesRoute: HermesVoiceRoute?

    public var selectedHermesRoute: HermesVoiceRoute { hermesRoute ?? .builtIn }

    public init?(kind: RemoteKind, address: String, hermesProfile: String? = nil,
                 hermesRoute: HermesVoiceRoute? = nil) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = hermesProfile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard kind != .codex, let parts = URLComponents(string: trimmed),
              parts.scheme == (kind == .openClaw ? "wss" : "https"),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              kind != .hermes || parts.path.isEmpty || parts.path == "/",
              kind == .hermes || hermesRoute == nil,
              profile.utf8.count <= 80,
              profile.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }),
              hermesRoute != .talkSubscription || profile.isEmpty || HermesTalkVoice.validProfile(profile),
              let url = parts.url else { return nil }
        self.kind = kind
        self.address = url.absoluteString
        self.hermesProfile = profile.isEmpty ? nil : profile
        self.hermesRoute = hermesRoute
    }

    func httpURL(path: String, includeProfile: Bool = true) -> URL? {
        guard var parts = URLComponents(string: address), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (kind == .openClaw && parts.scheme == "wss") else { return nil }
        parts.scheme = "https"
        parts.path = path
        if includeProfile, kind == .hermes, let hermesProfile {
            parts.queryItems = [URLQueryItem(name: "profile", value: hermesProfile)]
        }
        return parts.url
    }
}

public enum NativeVoiceError: LocalizedError, Equatable {
    case invalidEndpoint, invalidReply, unavailable, authentication, expired
    case openClawPairingRequired(String)
    case gatewayUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter the host’s private, certificate-validated voice endpoint."
        case .invalidReply: "The host returned an invalid voice response."
        case .unavailable: "This host hasn’t enabled compatible realtime voice."
        case .authentication: "The voice host rejected this credential."
        case .expired: "This voice attempt has already ended. Start a new call."
        case .openClawPairingRequired(let id): "Approve OpenClaw device request \(id) on the Gateway, then tap Pair again."
        case .gatewayUnavailable: "The gateway did not accept this voice session. Check Talk settings and chat permissions."
        }
    }
}

enum NativeVoiceHTTP {
    static func request(_ request: URLRequest) async throws -> Data {
        try await receive(request, limit: 128 * 1024)
    }

    static func receive(_ request: URLRequest, limit: Int) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 45
        let session = URLSession(configuration: config, delegate: NoRemoteRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw NativeVoiceError.invalidReply }
        if [401, 403].contains(response.statusCode) { throw NativeVoiceError.authentication }
        guard (200..<300).contains(response.statusCode) else { throw NativeVoiceError.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw NativeVoiceError.invalidReply }
            data.append(byte)
        }
        return data
    }

    static func checkedSDP(_ sdp: String?) throws -> String {
        guard let sdp, sdp.hasPrefix("v=0"), sdp.utf8.count <= 65_536 else { throw NativeVoiceError.invalidReply }
        return sdp
    }
}

public struct HermesVoiceLine: Equatable, Sendable {
    public let role: ChatRole
    public let text: String

    public init(role: ChatRole, text: String) {
        self.role = role
        self.text = text
    }
}

public struct HermesLiveVoice: Sendable {
    private let profile: NativeVoiceProfile
    private let token: String
    private let request: @Sendable (URLRequest) async throws -> Data

    public init?(profile: NativeVoiceProfile, token: String) {
        self.init(profile: profile, token: token, request: NativeVoiceHTTP.request)
    }

    init?(profile: NativeVoiceProfile, token: String, request: @escaping @Sendable (URLRequest) async throws -> Data) {
        guard profile.kind == .hermes, profile.selectedHermesRoute == .builtIn,
              RemoteProfile.validBearer(token) else { return nil }
        self.profile = profile
        self.token = token
        self.request = request
    }

    public func checkAvailability() async throws {
        let status = try await send(path: "/api/audio/voice-live/status")
        guard status["ok"] == .boolean(true), status["available"] == .boolean(true),
              status["mode"] == "gpt-live" else { throw NativeVoiceError.unavailable }
    }

    public func answer(offer: String, history: [HermesVoiceLine]) async throws -> String {
        let offer = try NativeVoiceHTTP.checkedSDP(offer)
        try await checkAvailability()
        let seed = history.suffix(12).map { line -> JSON in
            let assistant = line.role == .assistant
            return [
                "type": "message", "role": assistant ? "assistant" : "user",
                "content": .array([["type": assistant ? "output_text" : "input_text",
                                    "text": .string(String(line.text.prefix(600))) ]])
            ]
        }
        let response = try await send(path: "/api/audio/voice-live/session", body: [
            "sdp": .string(offer), "history": .array(seed)
        ])
        guard response["ok"] == .boolean(true), response["transport"]?["type"] == "webrtc" else {
            throw NativeVoiceError.invalidReply
        }
        return try NativeVoiceHTTP.checkedSDP(response["transport"]?["sdp"]?.string)
    }

    private func send(path: String, body: JSON? = nil) async throws -> JSON {
        guard let url = profile.httpURL(path: path) else { throw NativeVoiceError.invalidEndpoint }
        var outgoing = URLRequest(url: url)
        outgoing.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
        if let body {
            outgoing.httpMethod = "POST"
            outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type")
            outgoing.httpBody = try JSONEncoder().encode(body)
        }
        return try JSONDecoder().decode(JSON.self, from: await request(outgoing))
    }
}

public struct HermesLiveEvents: Sendable {
    public enum Event: Equatable, Sendable {
        case delegation(id: String, text: String)
        case closed
    }

    private var userSpeech = ""
    private var outputSinceInput = false
    private var endMilliseconds: Int?
    private var answered = Set<String>()

    public init() {}

    public mutating func clearInput() {
        userSpeech = ""
        outputSinceInput = false
        endMilliseconds = nil
    }

    public mutating func accept(_ data: Data, listening: Bool) -> Event? {
        guard data.count <= 64 * 1024, let frame = try? JSONDecoder().decode(JSON.self, from: data) else { return nil }
        switch frame["type"]?.string {
        case "session.input_transcript.delta" where listening:
            let start = Self.clock(frame["start_ms"]?.integer)
            if outputSinceInput || (start.flatMap { start in endMilliseconds.map { start > $0 + 1_800 } } ?? false) {
                clearInput()
            }
            if let delta = frame["delta"]?.string { userSpeech = String((userSpeech + delta).suffix(3_000)) }
            endMilliseconds = Self.clock(frame["end_ms"]?.integer) ?? endMilliseconds
            return nil
        case "session.output_transcript.delta":
            outputSinceInput = true
            return nil
        case "session.delegation.created" where listening:
            let text = userSpeech.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id = frame["delegation"]?["id"]?.string, !id.isEmpty, id.utf8.count <= 128,
                  !text.isEmpty, answered.count < 200, answered.insert(id).inserted else { return nil }
            clearInput()
            return .delegation(id: id, text: text)
        case "session.closed":
            clearInput()
            return .closed
        default:
            return nil
        }
    }

    public static func commentary(_ text: String, delegationID: String) -> [Data] {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var rest = Substring(clean.prefix(4_800))
        var frames: [Data] = []
        while !rest.isEmpty {
            let prefix = rest.prefix(1_200)
            let fragment: Substring
            if prefix.count == 1_200, let space = prefix.lastIndex(where: \.isWhitespace), space != prefix.startIndex {
                fragment = prefix[..<space]
            } else {
                fragment = prefix
            }
            let reply: JSON = [
                "type": "session.commentary.append", "delegation_id": .string(delegationID),
                "content": .string(String(fragment)), "event_id": .string(UUID().uuidString)
            ]
            if let frame = try? JSONEncoder().encode(reply) { frames.append(frame) }
            rest = rest.dropFirst(fragment.count).drop(while: \.isWhitespace)
        }
        return frames
    }

    public static func closeFrame() -> Data { Data("{\"type\":\"session.close\"}".utf8) }

    public static func muteFrame(_ muted: Bool) -> Data {
        let method = muted ? "mute" : "unmute"
        return Data("{\"type\":\"session.input_audio.\(method)\"}".utf8)
    }

    private static func clock(_ value: Int?) -> Int? {
        guard let value, (0...86_400_000).contains(value) else { return nil }
        return value
    }
}
