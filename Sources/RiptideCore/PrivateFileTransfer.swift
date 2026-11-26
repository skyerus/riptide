import Foundation

public struct PrivateFileTransfer: Sendable {
    public static let byteLimit = 1024 * 1024
    public let destination: String
    let makeTransport: @Sendable () -> SSHACPTransport?

    public func send(name: String, data: Data) async throws -> String {
        guard data.count <= Self.byteLimit else { throw TransferError.tooLarge }
        try Task.checkCancellation()
        guard let transport = makeTransport() else { throw TransferError.unavailable }

        let deadline = Task {
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            await transport.close()
        }
        defer {
            deadline.cancel()
            Task { await transport.close() }
        }

        return try await withTaskCancellationHandler {
            try await Self.exchange(name: name, data: data, transport: transport)
        } onCancel: {
            Task { await transport.close() }
        }
    }

    static func exchange(name: String, data: Data, transport: any JSONMessageTransport) async throws -> String {
        struct Ready: Decodable { let version: Int }
        struct Request: Encodable { let name: String; let dataBase64: Data }
        struct Receipt: Decodable { let path: String? }

        var replies = transport.incoming.makeAsyncIterator()
        guard let ready = try await replies.next(),
              (try? JSONDecoder().decode(Ready.self, from: ready).version) == 1 else {
            throw TransferError.unavailable
        }
        try Task.checkCancellation()
        let filename = ChatAttachment.hostFilename(for: name)
        let encoder = JSONEncoder()
        // Avoid expanding base64 slashes so even a full-size file fits the SSH frame.
        encoder.outputFormatting = .withoutEscapingSlashes
        try await transport.send(encoder.encode(Request(name: filename, dataBase64: data)))
        guard let reply = try await replies.next(),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: reply),
              let path = receipt.path,
              path.hasPrefix("/"), path.utf8.count <= 4_096,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw TransferError.notConfirmed
        }
        return path
    }

    private enum TransferError: LocalizedError {
        case tooLarge, unavailable, notConfirmed

        var errorDescription: String? {
            switch self {
            case .tooLarge: "Choose a file up to 1 MB."
            case .unavailable: "Private file transfer is unavailable. Update the Riptide host and try again."
            case .notConfirmed: "The VPS didn’t confirm the upload."
            }
        }
    }
}
