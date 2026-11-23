import Foundation

public enum HermesTalkVoiceError: LocalizedError, Equatable {
    case subscriptionRequired, wrongChat, lostBinding

    public var errorDescription: String? {
        switch self {
        case .subscriptionRequired:
            "This host must run Hermes Talk Live with ChatGPT subscription billing and task context enabled."
        case .wrongChat:
            "Hermes Talk couldn’t verify this chat in the paired profile."
        case .lostBinding:
            "The Hermes Talk connection ended. Reopen the call to reconnect."
        }
    }
}

public actor HermesTalkVoice {
    public enum Activity: Equatable, Sendable { case listening, working, result }

    private let profile: NativeVoiceProfile
    private let dashboardToken: String
    private let talkToken: String?
    private let request: @Sendable (URLRequest) async throws -> Data
    private let tab = UUID().uuidString.lowercased()
    private var context: [String: JSON]?
    private var bindingID: String?
    private var cursor = 0
    private var opening = false
    private var polling = false
    private var closed = false

    public init?(profile: NativeVoiceProfile, dashboardToken: String, talkToken: String? = nil) {
        self.init(profile: profile, dashboardToken: dashboardToken, talkToken: talkToken,
                  request: { request in
                      let limit = request.url?.path.hasSuffix("/live/events") == true ? (2 * 1024 + 4) * 1024 : 128 * 1024
                      return try await NativeVoiceHTTP.receive(request, limit: limit)
                  })
    }

    init?(profile: NativeVoiceProfile, dashboardToken: String, talkToken: String? = nil,
         request: @escaping @Sendable (URLRequest) async throws -> Data) {
        guard profile.kind == .hermes, profile.selectedHermesRoute == .talkSubscription,
              Self.validProfile(profile.hermesProfile ?? "default"), RemoteProfile.validBearer(dashboardToken),
              talkToken.map(RemoteProfile.validBearer) ?? true else { return nil }
        self.profile = profile
        self.dashboardToken = dashboardToken
        self.talkToken = talkToken
        self.request = request
    }

    nonisolated static func validProfile(_ name: String) -> Bool {
        validID(name, limit: 64) && !name.contains(".")
    }

    public func checkAvailability() async throws {
        let status = try await send("/status")
        guard status["ok"] == .boolean(true), status["configured"] == .boolean(true),
              status["voiceMode"] == "live", status["liveAuth"] == "subscription",
              status["source"] == "codex-oauth", status["taskContinuity"]?["supported"] == .boolean(true),
              let model = status["model"]?.string, ["gpt-live-1-codex", "gpt-live-1-boulder-alpha"].contains(model) else {
            throw HermesTalkVoiceError.subscriptionRequired
        }
    }

    public func answer(offer: String, sessionID: String) async throws -> String {
        guard !opening, !closed, context == nil else { throw NativeVoiceError.expired }
        let offer = try NativeVoiceHTTP.checkedSDP(offer)
        opening = true
        defer { opening = false }
        do {
            try await checkAvailability()
            let target = try await target(for: sessionID)
            try checkCurrent()
            let response = try await send("/native/attach", body: [
                "input_mode": "typed", "surface": "dashboard", "target_id": .string(target), "tab_id": .string(tab)
            ])
            let task = response["task"]
            if task?["tab_id"]?.string == tab, task?["target_id"]?.string == target,
               let id = task?["connection_id"]?.string, Self.validID(id),
               let generation = task?["generation"]?.integer, generation >= 0 {
                context = ["connection_id": .string(id), "generation": .integer(generation)]
            }
            guard let context, response["ok"] == .boolean(true), response["input_mode"] == "typed",
                  task?["session_id"]?.string == sessionID, task?["peer_id"] == "local",
                  task?["profile"]?.string == (profile.hermesProfile ?? "default"),
                  response["selection"]?["state"] == "activated",
                  response["selection"]?["target_id"]?.string == target else {
                throw HermesTalkVoiceError.wrongChat
            }
            try checkCurrent()
            try await checkAvailability()
            try checkCurrent()
            let live = try await send("/live/session", body: context.merging(["sdp": .string(offer)]) { existing, _ in existing },
                                      timeout: 38)
            if let id = live["binding_id"]?.string, Self.validID(id) { bindingID = id }
            try checkCurrent()
            guard bindingID != nil, live["ok"] == .boolean(true) else { throw NativeVoiceError.invalidReply }
            return try NativeVoiceHTTP.checkedSDP(live["sdp"]?.string)
        } catch {
            closed = true
            await release()
            throw error
        }
    }

    public func poll() async throws -> Activity? {
        try checkCurrent()
        guard !polling, let context, let bindingID else { throw NativeVoiceError.expired }
        polling = true
        defer { polling = false }
        var params = context
        params["binding_id"] = .string(bindingID)
        params["after"] = .integer(cursor)
        let response = try await send("/live/events", body: params)
        try checkCurrent()
        guard response["ok"] == .boolean(true), let last = response["cursor"]?.integer, last >= cursor,
              let events = response["events"]?.array else { throw NativeVoiceError.invalidReply }
        var activity: Activity?
        for event in events {
            guard let sequence = event["sequence"]?.integer, sequence > cursor, sequence - cursor == 1,
                  sequence <= last, let type = event["type"]?.string else { throw HermesTalkVoiceError.lostBinding }
            cursor = sequence
            switch type {
            case "operation":
                if case .boolean(let pending)? = event["pending"] { activity = pending ? .working : .listening }
            case "result":
                activity = .result
            case "error":
                throw HermesTalkVoiceError.lostBinding
            default:
                break
            }
        }
        guard cursor == last else { throw HermesTalkVoiceError.lostBinding }
        return activity
    }

    public func end() async {
        closed = true
        if !opening { await release() }
    }

    private func release() async {
        guard let context else { return }
        self.context = nil
        let id = bindingID
        bindingID = nil
        let cleanup = Task {
            if let id {
                var params = context
                params["binding_id"] = .string(id)
                _ = try? await self.send("/live/close", body: params)
            }
            _ = try? await self.send("/close", body: context)
        }
        await cleanup.value
    }

    private func target(for sessionID: String) async throws -> String {
        guard Self.validID(sessionID) else { throw HermesTalkVoiceError.wrongChat }
        let name = profile.hermesProfile ?? "default"
        let catalog = try await send("/targets", body: [
            "peer_id": "local", "profile": .string(name), "session_id": .string(sessionID), "tab_id": .string(tab)
        ])
        guard catalog["ok"] == .boolean(true), let targets = catalog["targets"]?.array else {
            throw HermesTalkVoiceError.wrongChat
        }
        let matches = targets.filter {
            $0["peer_id"] == "local" && $0["profile"]?.string == name && $0["session_id"]?.string == sessionID
        }
        guard matches.count == 1, let id = matches[0]["target_id"]?.string, Self.validID(id) else {
            throw HermesTalkVoiceError.wrongChat
        }
        return id
    }

    private func checkCurrent() throws {
        try Task.checkCancellation()
        guard !closed else { throw NativeVoiceError.expired }
    }

    private func send(_ path: String, body: [String: JSON]? = nil, timeout: TimeInterval = 10) async throws -> JSON {
        guard let url = profile.httpURL(path: "/api/plugins/hermes-talk" + path, includeProfile: false) else {
            throw NativeVoiceError.invalidEndpoint
        }
        var outgoing = URLRequest(url: url, timeoutInterval: timeout)
        outgoing.setValue(dashboardToken, forHTTPHeaderField: "X-Hermes-Session-Token")
        if let talkToken { outgoing.setValue(talkToken, forHTTPHeaderField: "X-Talk-Token") }
        if let body {
            outgoing.httpMethod = "POST"
            outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type")
            outgoing.httpBody = try JSONEncoder().encode(JSON.object(body))
        }
        return try JSONDecoder().decode(JSON.self, from: await request(outgoing))
    }

    nonisolated private static func validID(_ value: String, limit: Int = 256) -> Bool {
        guard let first = value.first, first.isASCII && (first.isLetter || first.isNumber),
              value.utf8.count <= limit else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }
}
