import CryptoKit
import Foundation

struct ChatHistoryCheckpoint: Codable, Equatable, Sendable {
    let rows: Int
    let digest: String

    var wire: JSON { ["rows": .integer(rows), "digest": .string(digest)] }

    init?(wire: JSON?) {
        guard let rows = wire?["rows"]?.integer, rows >= 0,
              let digest = wire?["digest"]?.string, digest.utf8.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        self.rows = rows
        self.digest = digest
    }
}

struct ChatHistorySnapshot: Codable, Sendable {
    let checkpoint: ChatHistoryCheckpoint
    let updates: [JSON]
}

public struct ChatHistoryCache: Sendable {
    private let directory: URL
    private static let byteLimit = 1_048_576
    private static let chatLimit = 8

    public init(workspace: String, root: URL = URL.cachesDirectory.appending(path: "ACPChatHistory-v1")) {
        directory = root.appending(path: Self.key(workspace))
    }

    func read(_ chat: String) -> ChatHistorySnapshot? {
        let url = file(chat)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.byteLimit,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ChatHistorySnapshot.self, from: data)
    }

    func modifiedAt(_ chat: String) -> Date? {
        try? file(chat).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    func write(_ snapshot: ChatHistorySnapshot, chat: String) {
        let url = file(chat)
        guard let data = try? JSONEncoder().encode(snapshot), data.count <= Self.byteLimit else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            let keys: Set<URLResourceKey> = [.contentModificationDateKey]
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
            let others = files.filter { $0 != url }.sorted {
                ((try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast) >
                    ((try? $1.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast)
            }
            for old in others.dropFirst(Self.chatLimit - 1) { try? FileManager.default.removeItem(at: old) }
        } catch {
            // A locked or unavailable cache never prevents connecting to the live chat.
        }
    }

    public func removeWorkspace() { try? FileManager.default.removeItem(at: directory) }

    private func file(_ chat: String) -> URL { directory.appending(path: Self.key(chat)) }

    private static func key(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
