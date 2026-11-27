import Foundation

public enum CodexDictationError: LocalizedError {
    case unavailable, invalidAudio, connectionClosed, timedOut, invalidResponse
    case signIn, accountChanged, serviceUnavailable, noSpeech

    public var errorDescription: String? {
        switch self {
        case .unavailable, .connectionClosed:
            "Dictation could not reach the Codex relay on this host."
        case .invalidAudio: "The recording was empty or too large. Try a shorter recording."
        case .timedOut: "Codex took too long to transcribe the recording."
        case .invalidResponse, .serviceUnavailable:
            "Codex could not transcribe this recording. Try again."
        case .signIn: "Sign in to Codex with ChatGPT on the paired host to use dictation."
        case .accountChanged: "The host’s Codex account changed. Pair it again to use dictation."
        case .noSpeech: "Codex did not detect any speech in the recording."
        }
    }
}

public struct CodexDictation: Sendable {
    // The Codex desktop client's non-streaming dictation limit is 9:55.
    public static let maximumDuration: TimeInterval = 595
    public static let maximumAudioBytes = 5_000_000
    static let maximumRequestBytes = 6_700_000
    private static let timeout: TimeInterval = 135
    private let connect: @Sendable () throws -> any JSONMessageTransport
    private let accountFingerprint: String?

    init(accountFingerprint: String? = nil,
         connect: @escaping @Sendable () throws -> any JSONMessageTransport) {
        self.connect = connect
        self.accountFingerprint = accountFingerprint
    }

    static func webSocket(at url: URL, bearer: String, accountFingerprint: String? = nil) -> Self {
        let relay = URLComponents(url: url, resolvingAgainstBaseURL: false).flatMap { original -> URL? in
            var route = original
            route.path = "/riptide-dictation"
            return route.url
        }
        return Self(accountFingerprint: accountFingerprint) {
            guard let relay else { throw CodexDictationError.unavailable }
            return RemoteWebSocketTransport(url: relay, bearer: bearer, requestTimeout: timeout)
        }
    }

    public func transcribe(_ audio: Data) async throws -> String {
        guard !audio.isEmpty, audio.count <= Self.maximumAudioBytes else { throw CodexDictationError.invalidAudio }
        try Task.checkCancellation()
        let request = Request(audio: audio, accountFingerprint: accountFingerprint)
        let connect = connect
        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .withoutEscapingSlashes
                    let transport = try connect()
                    try await transport.send(encoder.encode(request))
                    var frames = transport.incoming.makeAsyncIterator()
                    guard let frame = try await frames.next() else { throw CodexDictationError.connectionClosed }
                    guard let reply = try? JSONDecoder().decode(Reply.self, from: frame) else {
                        throw CodexDictationError.invalidResponse
                    }
                    if let error = reply.error { throw error.failure }
                    guard let text = reply.text?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                        throw CodexDictationError.invalidResponse
                    }
                    guard !text.isEmpty else { throw CodexDictationError.noSpeech }
                    return text
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(Self.timeout))
                    throw CodexDictationError.timedOut
                }
                defer { group.cancelAll() }
                guard let transcript = try await group.next() else { throw CodexDictationError.connectionClosed }
                try Task.checkCancellation()
                return transcript
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CodexDictationError {
            throw error
        } catch {
            throw CodexDictationError.connectionClosed
        }
    }

    private struct Request: Encodable, Sendable {
        let audio: Data
        let accountFingerprint: String?
    }

    private struct Reply: Decodable {
        let text: String?
        let error: Rejection?
    }

    private enum Rejection: String, Decodable {
        case disabled, invalidAudio, signIn, accountChanged, serviceUnavailable, noSpeech

        var failure: CodexDictationError {
            switch self {
            case .disabled: .unavailable
            case .invalidAudio: .invalidAudio
            case .signIn: .signIn
            case .accountChanged: .accountChanged
            case .serviceUnavailable: .serviceUnavailable
            case .noSpeech: .noSpeech
            }
        }
    }
}
