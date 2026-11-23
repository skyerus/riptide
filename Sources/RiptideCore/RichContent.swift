import Foundation

public struct MarkdownStreamSource: Equatable, Sendable {
    public let committed: String
    public let pending: String

    public init(_ source: String, streaming: Bool) {
        guard streaming else {
            committed = source
            pending = ""
            return
        }
        guard let newline = source.lastIndex(where: \.isNewline) else {
            committed = ""
            pending = source
            return
        }
        let boundary = source.index(after: newline)
        committed = String(source[..<boundary])
        pending = String(source[boundary...])
    }

    public static func closesFence(opening: Substring, closing: Substring) -> Bool {
        let opener = opening.drop(while: { $0 == " " || $0 == "\t" })
        guard let marker = opener.first, marker == "`" || marker == "~" else { return false }
        let openingCount = opener.prefix(while: { $0 == marker }).count
        guard openingCount >= 3 else { return false }
        let closer = closing.drop(while: { $0 == " " || $0 == "\t" || $0 == ">" })
        let closingCount = closer.prefix(while: { $0 == marker }).count
        return closingCount >= openingCount && closer.dropFirst(closingCount).allSatisfy { $0.isWhitespace }
    }
}

public struct UnifiedDiff: Equatable, Sendable {
    public enum Kind: Sendable {
        case file, hunk, addition, deletion, context, metadata
    }

    public struct Line: Equatable, Sendable {
        public let text: String
        public let kind: Kind
        public let oldNumber: Int?
        public let newNumber: Int?
    }

    public let lines: [Line]
    public let additions: Int
    public let deletions: Int
    public let truncated: Bool

    public init(_ source: String, limit: Int = 400) {
        var lines: [Line] = []
        var oldNumber: Int?
        var newNumber: Int?
        var adds = 0
        var deletes = 0
        var truncated = false
        var remainingOld = 0
        var remainingNew = 0
        let lowerBound = max(0, limit)
        source.enumerateLines { text, stop in
            guard lines.count < lowerBound else {
                truncated = true
                stop = true
                return
            }
            var previous: Int?
            var next: Int?
            let kind: Kind
            if text.hasPrefix("diff --git ") {
                kind = .file
                remainingOld = 0
                remainingNew = 0
            } else if let hunk = text.prefixMatch(of: /^@@ -(\d{1,9})(?:,(\d{1,9}))? \+(\d{1,9})(?:,(\d{1,9}))? @@/) {
                kind = .hunk
                oldNumber = Int(hunk.1)
                newNumber = Int(hunk.3)
                remainingOld = hunk.2.flatMap { Int($0) } ?? 1
                remainingNew = hunk.4.flatMap { Int($0) } ?? 1
            } else if remainingNew > 0, text.hasPrefix("+") {
                kind = .addition
                next = newNumber
                newNumber = newNumber.map { $0 + 1 }
                remainingNew -= 1
                adds += 1
            } else if remainingOld > 0, text.hasPrefix("-") {
                kind = .deletion
                previous = oldNumber
                oldNumber = oldNumber.map { $0 + 1 }
                remainingOld -= 1
                deletes += 1
            } else if remainingOld > 0, remainingNew > 0, text.hasPrefix(" ") {
                kind = .context
                previous = oldNumber
                next = newNumber
                oldNumber = oldNumber.map { $0 + 1 }
                newNumber = newNumber.map { $0 + 1 }
                remainingOld -= 1
                remainingNew -= 1
            } else if text.hasPrefix("+++ ") || text.hasPrefix("--- ") {
                kind = .file
            } else if text.hasPrefix("+") {
                kind = .addition
                adds += 1
            } else if text.hasPrefix("-") {
                kind = .deletion
                deletes += 1
            } else {
                kind = .metadata
            }
            lines.append(Line(text: text, kind: kind, oldNumber: previous, newNumber: next))
        }
        self.lines = lines
        additions = adds
        deletions = deletes
        self.truncated = truncated
    }
}
