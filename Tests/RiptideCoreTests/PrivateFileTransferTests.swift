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
        let path = try await PrivateFileTransfer.exchange(name: "../client.json", data: bytes, transport: transport)
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
                try await PrivateFileTransfer.exchange(name: "secret", data: Data([9]), transport: transport)
            }
            #expect(await transport.sent.isEmpty)
        }
    }

    @Test func aFullSizeBinaryFileFitsTheSSHFrame() async throws {
        struct Upload: Decodable { let dataBase64: Data }
        let transport = TransferTransport(frames: [#"{"version":1}"#, #"{"path":"/tmp/private/upload"}"#])
        let bytes = Data(repeating: 255, count: PrivateFileTransfer.byteLimit)
        _ = try await PrivateFileTransfer.exchange(name: "upload", data: bytes, transport: transport)
        let messages = await transport.sent
        let frame = try #require(messages.first)
        #expect(frame.count < 2 * 1024 * 1024)
        #expect(try JSONDecoder().decode(Upload.self, from: frame).dataBase64 == bytes)
    }

    @Test func anUnconfirmedOrUnsafeReceiptFails() async {
        for replies in [[], [#"{"error":"uploadRejected"}"#], [#"{"path":"relative"}"#], [#"{"path":"/one\ntwo"}"#]] {
            let transport = TransferTransport(frames: [#"{"version":1}"#] + replies)
            await #expect(throws: (any Error).self) {
                try await PrivateFileTransfer.exchange(name: "file", data: Data([9]), transport: transport)
            }
        }
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
