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

    static func messageText(_ text: String, attachments: [ChatAttachment]) -> String {
        ([text] + attachments.map { "Attached: \($0.name)" })
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public static let maxCount = 4
    public static let codexByteLimit = 8 * 1024 * 1024
    // ACP bridges admit a 2 MiB JSON frame. Leave room for base64, metadata and the prompt.
    public static let acpByteLimit = 1024 * 1024
}
