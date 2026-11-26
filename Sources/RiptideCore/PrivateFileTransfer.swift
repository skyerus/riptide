import Foundation

public struct PrivateFileTransfer: Sendable {
    public static let byteLimit = 100 * 1024 * 1024
    static let legacyLimit = 1024 * 1024
    static let chunkLimit = 512 * 1024
    private static let idleTimeout = Duration.seconds(60)

    public let destination: String
    let makeTransport: @Sendable () -> SSHACPTransport?

    @concurrent public func send(file url: URL, progress: @Sendable (Int, Int) async -> Void) async throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file: FileHandle
        let size: Int
        do {
            let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard properties.isRegularFile == true, let fileSize = properties.fileSize, fileSize >= 0 else {
                throw TransferError.unreadable
            }
            size = fileSize
            file = try FileHandle(forReadingFrom: url)
        } catch {
            throw TransferError.unreadable
        }
        defer { try? file.close() }
        guard size <= Self.byteLimit else { throw TransferError.tooLarge }

        try Task.checkCancellation()
        guard let transport = makeTransport() else { throw TransferError.unavailable }
        let activity = TransferActivity()
        let deadline = Task {
            while !Task.isCancelled {
                let remaining = await activity.remaining(until: Self.idleTimeout)
                if remaining <= .zero {
                    await transport.close()
                    return
                }
                do { try await Task.sleep(for: remaining) } catch { return }
            }
        }
        defer {
            deadline.cancel()
            Task { await transport.close() }
        }

        return try await withTaskCancellationHandler {
            try await Self.exchange(name: url.lastPathComponent, size: size, transport: transport) { count in
                do { return try file.read(upToCount: count) ?? Data() }
                catch { throw TransferError.unreadable }
            } progress: { sent, total in
                await activity.record()
                await progress(sent, total)
            }
        } onCancel: {
            Task { await transport.close() }
        }
    }

    static func exchange(name: String, size: Int, transport: any JSONMessageTransport,
                         read: (Int) throws -> Data, progress: (Int, Int) async -> Void) async throws -> String {
        struct Streaming: Decodable { let chunkBytes: Int; let byteLimit: Int }
        struct Ready: Decodable { let version: Int; let streaming: Streaming? }
        struct Start: Encodable { let name: String; let size: Int }
        struct LegacyUpload: Encodable { let name: String; let dataBase64: Data }
        struct Chunk: Encodable { let dataBase64: Data }
        struct Finish: Encodable { let complete = true }
        struct Reply: Decodable { let received: Int?; let path: String? }

        guard (0...byteLimit).contains(size) else { throw TransferError.tooLarge }
        let decoder = JSONDecoder()
        var replies = transport.incoming.makeAsyncIterator()
        guard let greeting = try await replies.next(),
              let ready = try? decoder.decode(Ready.self, from: greeting), ready.version == 1 else {
            throw TransferError.unavailable
        }
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        // Base64 may contain slashes. Keep them unescaped to bound the frame size.
        encoder.outputFormatting = .withoutEscapingSlashes
        let filename = ChatAttachment.hostFilename(for: name)
        await progress(0, size)

        if let streaming = ready.streaming {
            guard (1...chunkLimit).contains(streaming.chunkBytes), streaming.byteLimit > 0 else {
                throw TransferError.unavailable
            }
            guard size <= streaming.byteLimit else { throw TransferError.hostLimit }
            try await transport.send(encoder.encode(Start(name: filename, size: size)))

            var sent = 0
            while true {
                try Task.checkCancellation()
                guard let frame = try await replies.next(),
                      (try? decoder.decode(Reply.self, from: frame).received) == sent else {
                    throw TransferError.notConfirmed
                }
                await progress(sent, size)
                try Task.checkCancellation()
                guard sent < size else { break }
                let count = min(streaming.chunkBytes, size - sent)
                let bytes = try read(count)
                guard !bytes.isEmpty, bytes.count <= count else { throw TransferError.fileChanged }
                try await transport.send(encoder.encode(Chunk(dataBase64: bytes)))
                sent += bytes.count
            }
            guard try read(1).isEmpty else { throw TransferError.fileChanged }
            try Task.checkCancellation()
            try await transport.send(encoder.encode(Finish()))
        } else {
            guard size <= legacyLimit else { throw TransferError.hostLimit }
            var bytes = Data(capacity: size)
            while bytes.count < size {
                try Task.checkCancellation()
                let remaining = size - bytes.count
                let part = try read(remaining)
                guard !part.isEmpty, part.count <= remaining else { throw TransferError.fileChanged }
                bytes.append(part)
            }
            guard try read(1).isEmpty else { throw TransferError.fileChanged }
            try Task.checkCancellation()
            try await transport.send(encoder.encode(LegacyUpload(name: filename, dataBase64: bytes)))
        }

        guard let frame = try await replies.next(),
              let path = (try? decoder.decode(Reply.self, from: frame))?.path,
              path.hasPrefix("/"), path.utf8.count <= 4_096,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw TransferError.notConfirmed
        }
        return path
    }

    private enum TransferError: LocalizedError {
        case unreadable, fileChanged, tooLarge, hostLimit, unavailable, notConfirmed

        var errorDescription: String? {
            switch self {
            case .unreadable: "Riptide couldn’t read the selected file."
            case .fileChanged: "The selected file changed during upload. Choose it again and retry."
            case .tooLarge: "Choose a file up to 100 MiB."
            case .hostLimit: "This VPS needs a Riptide host update to accept a file of this size."
            case .unavailable: "Private file transfer is unavailable. Update the Riptide host and try again."
            case .notConfirmed: "The VPS didn’t confirm the upload."
            }
        }
    }
}

private actor TransferActivity {
    private var lastActivity = ContinuousClock.now
    func record() { lastActivity = .now }
    func remaining(until limit: Duration) -> Duration { limit - lastActivity.duration(to: .now) }
}
