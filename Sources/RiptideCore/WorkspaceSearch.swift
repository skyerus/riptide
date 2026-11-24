import Foundation

public struct WorkspaceSearch: Sendable {
    private let terms: [String]
    private let phrase: String

    public init(_ query: String) {
        terms = Self.words(query)
        phrase = terms.joined(separator: " ")
    }

    public var isEmpty: Bool { terms.isEmpty }

    public func score(title: String, context: String = "") -> Int? {
        if isEmpty { return 0 }
        let main = Self.words(title)
        let contextWords = Self.words(context)
        var score = 0
        for term in terms {
            let matches: Int
            if main.contains(term) { matches = 7 }
            else if contextWords.contains(term) { matches = 5 }
            else if main.contains(where: { $0.hasPrefix(term) }) { matches = 4 }
            else if contextWords.contains(where: { $0.hasPrefix(term) }) { matches = 2 }
            else if main.contains(where: { $0.contains(term) }) { matches = 1 }
            else { return nil }
            score += matches
        }
        let text = main.joined(separator: " ")
        if text == phrase { score += 20 }
        else if text.hasPrefix(phrase) { score += 8 }
        return score
    }

    private static func words(_ value: String) -> [String] {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
