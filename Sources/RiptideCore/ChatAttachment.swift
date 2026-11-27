import CryptoKit
import Foundation

public struct ChatAttachment: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let name: String
    public let data: Data
    public let imageMIMEType: String?

    public init(name: String, data: Data, imageMIMEType: String? = nil) {
        self.name = name.replacingOccurrences(of: #"[\x00-\x1F\x7F]"#, with: " ", options: .regularExpression)
        self.data = data
        self.imageMIMEType = imageMIMEType
    }

    var hostFilename: String { Self.hostFilename(for: name) }

    static func hostFilename(for name: String) -> String {
        let filename = String(name.prefix(120).map { character in
            character.isASCII && (character.isLetter || character.isNumber || "._-".contains(character))
                ? character : "_"
        }).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return filename.isEmpty ? "attachment" : filename
    }

    var inlineText: String? {
        guard imageMIMEType == nil, data.count <= 64 * 1024, !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func reference(to path: String) -> String { "Attached file: \(name)\nHost path: \(path)" }

    public static func messageText(_ text: String, attachments: [ChatAttachment]) -> String {
        ([text] + attachments.map { "Attached: \($0.name)" })
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public static let maxCount = 4
    public static let codexByteLimit = 8 * 1024 * 1024
    // ACP bridges admit a 2 MiB JSON frame. Leave room for base64, metadata and the prompt.
    public static let acpByteLimit = 1024 * 1024
}


public struct TranscriptPhoto: Codable, Equatable, Sendable {
    public enum Source: Codable, Hashable, Sendable {
        case data(Data)
        case codexPath(String)
        case unavailable
    }

    public let name: String
    public let source: Source

    public init(name: String, source: Source) {
        self.name = name
        self.source = source
    }
}

public struct SentPhotoMessage: Codable, Equatable, Sendable {
    public let text: String
    public let photos: [TranscriptPhoto]

    public init(text: String, attachments: [ChatAttachment]) {
        self.text = ChatAttachment.messageText(text, attachments: attachments.filter { $0.imageMIMEType == nil })
        photos = attachments.compactMap { file in
            guard file.imageMIMEType != nil else { return nil }
            return TranscriptPhoto(name: file.name, source: .data(file.data))
        }
    }
}

public struct SentPhotoStore: Sendable {
    private let directory: URL

    public init(workspace: String, root: URL = URL.applicationSupportDirectory.appending(path: "SentChatPhotos")) {
        directory = root.appending(path: Self.digest(workspace))
    }

    public func save(_ message: SentPhotoMessage, id: String, chat: String) throws {
        let url = file(id: id, chat: chat)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(message).write(to: url, options: [.atomic, .completeFileProtection])
    }

    public func read(id: String, chat: String) -> SentPhotoMessage? {
        guard let data = try? Data(contentsOf: file(id: id, chat: chat)) else { return nil }
        return try? JSONDecoder().decode(SentPhotoMessage.self, from: data)
    }

    public func remove(id: String, chat: String) {
        try? FileManager.default.removeItem(at: file(id: id, chat: chat))
    }

    public func removeWorkspace() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(id: String, chat: String) -> URL {
        directory.appending(path: Self.digest(chat)).appending(path: Self.digest(id))
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
