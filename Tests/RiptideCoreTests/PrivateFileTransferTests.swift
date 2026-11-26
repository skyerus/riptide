import Foundation
import Testing
@testable import RiptideCore

struct PrivateFileTransferTests {
    @Test func onlyAPinnedPairingCanTransferFiles() throws {
        let pin = "SHA256:" + Data(repeating: 7, count: 32).base64EncodedString().dropLast()
        let credential = SSHDeviceIdentity().privateCredential
        for kind in [RemoteKind.hermes, .openClaw] {
            let ssh = try #require(RemoteProfile(kind: kind, name: "VPS", address: "ssh://agent@example.invalid",
                                                   workspace: "/work", mainSessionID: "main", sshHostFingerprint: pin))
            let webSocket = try #require(RemoteProfile(kind: kind, name: "VPS", address: "wss://example.invalid/acp",
                                                         workspace: "/work", mainSessionID: "main"))
            #expect(ssh.makePrivateFileTransfer(credential: credential)?.destination == "VPS")
            #expect(ssh.makePrivateFileTransfer(credential: "invalid") == nil)
            #expect(webSocket.makePrivateFileTransfer(credential: credential) == nil)
        }
    }

    @Test func transferSendsOnlyTheSanitizedFilenameAndFileAfterTheHandshake() async throws {
        let transport = TransferTransport(frames: [#"{"version":1}"#, #"{"path":"/tmp/private/client.json"}"#])
        let bytes = Data([0, 1, 2, 255])
        let path = try await exchange(name: "../client.json", bytes: bytes, transport: transport)
        #expect(path == "/tmp/private/client.json")
        let messages = await transport.sent
        #expect(messages.count == 1)
        let sent = try JSONDecoder().decode([String: String].self, from: #require(messages.first))
        #expect(sent == ["name": "_client.json", "dataBase64": bytes.base64EncodedString()])
    }

    @Test func aMissingOrUnknownHandshakeNeverSendsBytes() async {
        for frames in [[], [#"{"version":2}"#], [#"{"path":"/tmp/unrelated"}"#]] {
            let transport = TransferTransport(frames: frames)
            await #expect(throws: (any Error).self) {
                try await exchange(name: "secret", bytes: Data([9]), transport: transport)
            }
            #expect(await transport.sent.isEmpty)
        }
    }

    @Test func aFullSizeBinaryFileFitsTheSSHFrame() async throws {
        struct Upload: Decodable { let dataBase64: Data }
        let transport = TransferTransport(frames: [#"{"version":1}"#, #"{"path":"/tmp/private/upload"}"#])
        let bytes = Data(repeating: 255, count: PrivateFileTransfer.legacyLimit)
        _ = try await exchange(name: "upload", bytes: bytes, transport: transport)
        let messages = await transport.sent
        let frame = try #require(messages.first)
        #expect(frame.count < 2 * 1024 * 1024)
        #expect(try JSONDecoder().decode(Upload.self, from: frame).dataBase64 == bytes)
    }

    @Test func streamingWaitsForAcknowledgementsAndSendsBoundedChunks() async throws {
        struct Chunk: Decodable { let dataBase64: Data }
        let transport = TransferTransport(frames: [
            #"{"version":1,"streaming":{"byteLimit":104857600,"chunkBytes":3}}"#,
            #"{"received":0}"#, #"{"received":3}"#, #"{"received":5}"#, #"{"path":"/tmp/private/file"}"#
        ])
        let path = try await exchange(name: "../file", bytes: Data([0, 1, 2, 3, 4]), transport: transport)
        #expect(path == "/tmp/private/file")
        let sent = await transport.sent
        try #require(sent.count == 4)
        let header = try JSONSerialization.jsonObject(with: sent[0]) as? NSDictionary
        #expect(header == ["name": "_file", "size": 5] as NSDictionary)
        #expect(try JSONDecoder().decode(Chunk.self, from: sent[1]).dataBase64 == Data([0, 1, 2]))
        #expect(try JSONDecoder().decode(Chunk.self, from: sent[2]).dataBase64 == Data([3, 4]))
        #expect(try JSONDecoder().decode([String: Bool].self, from: sent[3]) == ["complete": true])
    }

    @Test func invalidAcknowledgementStopsBeforeReadingOrSendingFileData() async {
        let transport = TransferTransport(frames: [
            #"{"version":1,"streaming":{"byteLimit":104857600,"chunkBytes":3}}"#, #"{"received":1}"#
        ])
        await #expect(throws: (any Error).self) {
            try await PrivateFileTransfer.exchange(name: "file", size: 5, transport: transport) { _ in
                Issue.record("An invalid acknowledgement must stop the transfer before reading.")
                return Data()
            } progress: { _, _ in }
        }
        #expect(await transport.sent.count == 1)
    }

    @Test func aLargeFileDoesNotSendAnythingToAnOldHost() async {
        let transport = TransferTransport(frames: [#"{"version":1}"#])
        await #expect(throws: (any Error).self) {
            try await PrivateFileTransfer.exchange(name: "file", size: PrivateFileTransfer.legacyLimit + 1,
                                                   transport: transport) { _ in
                Issue.record("The client must check the host limit before reading.")
                return Data()
            } progress: { _, _ in }
        }
        #expect(await transport.sent.isEmpty)
    }

    @Test func anUnconfirmedOrUnsafeReceiptFails() async {
        for replies in [[], [#"{"error":"uploadRejected"}"#], [#"{"path":"relative"}"#], [#"{"path":"/one\ntwo"}"#]] {
            let transport = TransferTransport(frames: [#"{"version":1}"#] + replies)
            await #expect(throws: (any Error).self) {
                try await exchange(name: "file", bytes: Data([9]), transport: transport)
            }
        }
    }

    private func exchange(name: String, bytes: Data, transport: TransferTransport) async throws -> String {
        var offset = 0
        return try await PrivateFileTransfer.exchange(name: name, size: bytes.count, transport: transport) { count in
            let end = min(offset + count, bytes.count)
            defer { offset = end }
            return bytes[offset..<end]
        } progress: { _, _ in }
    }
}

private actor TransferTransport: JSONMessageTransport {
    let incoming: AsyncThrowingStream<Data, any Error>
    private(set) var sent: [Data] = []

    init(frames: [String]) {
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        for frame in frames { continuation.yield(Data(frame.utf8)) }
        continuation.finish()
        incoming = stream
    }

    func send(_ message: Data) async throws { sent.append(message) }
}
