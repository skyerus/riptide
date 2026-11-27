import Foundation

actor HermesSSHTalk: HermesTalkCalling {
    private let connect: @Sendable () -> SSHACPTransport?
    private var transport: SSHACPTransport?
    private var started = false
    private var polling = false
    private var closed = false
    private var events = HermesTalkEvents()

    init(connect: @escaping @Sendable () -> SSHACPTransport?) {
        self.connect = connect
    }

    func answer(offer: String, sessionID: String) async throws -> String {
        guard !closed, transport == nil else { throw NativeVoiceError.expired }
        let offer = try NativeVoiceHTTP.checkedSDP(offer)
        try Task.checkCancellation()
        guard let transport = connect() else { throw NativeVoiceError.authentication }
        self.transport = transport
        do {
            let reply = try await Self.exchange([
                "operation": "start", "sessionID": .string(sessionID), "sdp": .string(offer)
            ], over: transport, timeout: .seconds(44))
            guard !closed else { throw NativeVoiceError.expired }
            let answer = try NativeVoiceHTTP.checkedSDP(reply["sdp"]?.string)
            started = true
            return answer
        } catch {
            await end()
            throw error
        }
    }

    func poll() async throws -> HermesTalkVoice.Activity? {
        guard !closed, started, !polling, let transport else { throw NativeVoiceError.expired }
        polling = true
        defer { polling = false }
        let reply = try await Self.exchange([
            "operation": "events", "after": .integer(events.cursor)
        ], over: transport, timeout: .seconds(12))
        guard !closed else { throw NativeVoiceError.expired }
        return try events.accept(reply)
    }

    func end() async {
        closed = true
        let transport = transport
        self.transport = nil
        // Closing the call channel releases its host-side Talk binding.
        await transport?.close()
    }

    private static func exchange(_ request: JSON, over transport: SSHACPTransport,
                                 timeout: Duration) async throws -> JSON {
        try await withThrowingTaskGroup(of: JSON.self) { group in
            group.addTask {
                try await transport.send(JSONEncoder().encode(request))
                var frames = transport.incoming.makeAsyncIterator()
                guard let frame = try await frames.next() else { throw NativeVoiceError.sshTalkUnavailable }
                let reply = try JSONDecoder().decode(JSON.self, from: frame)
                switch reply["error"]?.string {
                case "disabled": throw NativeVoiceError.sshTalkUnavailable
                case "subscription": throw HermesTalkVoiceError.subscriptionRequired
                case "wrongChat": throw HermesTalkVoiceError.wrongChat
                case "authentication": throw NativeVoiceError.authentication
                case "unavailable": throw NativeVoiceError.unavailable
                default:
                    guard reply["ok"] == .boolean(true) else { throw NativeVoiceError.invalidReply }
                    return reply
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw NativeVoiceError.timedOut
            }
            defer { group.cancelAll() }
            guard let reply = try await group.next() else { throw NativeVoiceError.expired }
            try Task.checkCancellation()
            return reply
        }
    }
}
