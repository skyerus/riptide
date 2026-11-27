import Foundation
import Testing
@testable import RiptideCore

struct CodexDictationTests {
    @Test func fullSizeAudioFitsInOneRelayRequest() async throws {
        struct Upload: Decodable {
            let audio: Data
            let accountFingerprint: String
        }

        let fingerprint = Data(repeating: 255, count: 32).base64EncodedString()
        let audio = Data(repeating: 255, count: CodexDictation.maximumAudioBytes)
        let dictation = CodexDictation(accountFingerprint: fingerprint) {
            DictationTransport { frame in
                #expect(frame.count <= CodexDictation.maximumRequestBytes)
                let upload = try JSONDecoder().decode(Upload.self, from: frame)
                #expect(upload.audio == audio)
                #expect(upload.accountFingerprint == fingerprint)
            }
        }

        #expect(try await dictation.transcribe(audio) == "Long dictation.")
    }
}

private struct DictationTransport: JSONMessageTransport {
    let receiveUpload: @Sendable (Data) throws -> Void
    let incoming = AsyncThrowingStream<Data, any Error> {
        $0.yield(Data(#"{"text":"Long dictation."}"#.utf8))
        $0.finish()
    }

    func send(_ message: Data) async throws {
        try receiveUpload(message)
    }
}
