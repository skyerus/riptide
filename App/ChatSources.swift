import Markdown
import SwiftUI

struct ChatSource: Equatable {
    let title: String
    let url: URL

    var domain: String {
        let host = url.host() ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

struct ChatSourceFooter {
    let blockCount: Int
    private let entries: [Entry]

    private struct Entry {
        let number: Int?
        let source: ChatSource
    }

    var sources: [ChatSource] { Self.unique(entries.map(\.source)) }

    init?(blocks: [any Markup]) {
        guard let last = blocks.last else { return nil }
        if let paragraph = last as? Paragraph,
           let entries = Self.read(paragraph, afterLabel: true), !entries.isEmpty {
            self.init(entries: entries, blockCount: 1)
        } else if blocks.count >= 2, let list = last as? any ListItemContainer,
                  Self.isLabel(blocks[blocks.count - 2]) {
            let start = (last as? OrderedList).flatMap { Int(exactly: $0.startIndex) }
            var entries: [Entry] = []
            for (index, item) in list.children.enumerated() {
                guard item.childCount == 1, let paragraph = item.child(at: 0) as? Paragraph,
                      let links = Self.read(paragraph), links.count == 1, let link = links.first else { return nil }
                entries.append(Entry(number: link.number ?? start.map { $0 + index }, source: link.source))
            }
            self.init(entries: entries, blockCount: 2)
        } else {
            return nil
        }
    }

    private init?(entries: [Entry], blockCount: Int) {
        let numbered = entries.compactMap(\.number)
        guard !entries.isEmpty, Set(numbered).count == numbered.count else { return nil }
        self.entries = entries
        self.blockCount = blockCount
    }

    func sources(numbered numbers: [Int]) -> [ChatSource] {
        Self.unique(numbers.compactMap { number in entries.first { $0.number == number }?.source })
    }

    func citing(_ text: AttributedString) -> SwiftUI.Text {
        let known = Set(entries.compactMap(\.number))
        guard !known.isEmpty else { return SwiftUI.Text(text) }
        let plain = String(text.characters)
        var groups: [(range: Range<String.Index>, numbers: [Int])] = []
        for match in plain.matches(of: /\[([0-9]+)\]/) {
            guard let number = Int(match.1), known.contains(number),
                  let lower = AttributedString.Index(match.range.lowerBound, within: text),
                  let upper = AttributedString.Index(match.range.upperBound, within: text),
                  text[lower..<upper].runs.allSatisfy({
                      $0.link == nil && $0.inlinePresentationIntent?.contains(.code) != true
                  }) else { continue }
            if let previous = groups.last,
               plain[previous.range.upperBound..<match.range.lowerBound].allSatisfy({ $0 == " " || $0 == "\t" }) {
                groups[groups.count - 1] = (previous.range.lowerBound..<match.range.upperBound, previous.numbers + [number])
            } else {
                groups.append((match.range, [number]))
            }
        }

        guard !groups.isEmpty else { return SwiftUI.Text(text) }
        var rendered = SwiftUI.Text(verbatim: "")
        var cursor = text.startIndex
        for group in groups {
            let destinations = sources(numbered: group.numbers)
            let ids = group.numbers.map(String.init).joined(separator: ",")
            guard let first = destinations.first,
                  let url = URL(string: "riptide-citation://sources/\(ids)"),
                  let lower = AttributedString.Index(group.range.lowerBound, within: text),
                  let upper = AttributedString.Index(group.range.upperBound, within: text) else { continue }
            let prose = SwiftUI.Text(AttributedString(text[cursor..<lower]))
            rendered = SwiftUI.Text("\(rendered)\(prose)")
            if group.range.lowerBound > plain.startIndex, !plain[plain.index(before: group.range.lowerBound)].isWhitespace {
                rendered = SwiftUI.Text("\(rendered) ")
            }
            let remaining = destinations.count - 1
            let label = remaining == 0 ? first.domain : "\(first.domain)\u{202F}+\(remaining)"
            var citation = AttributedString("\u{00A0}\(label)\u{00A0}")
            citation.link = url
            citation.font = .caption.weight(.medium)
            citation.foregroundColor = .primary
            let badge = SwiftUI.Text(citation).customAttribute(ChatCitationBadge())
            rendered = SwiftUI.Text("\(rendered)\(badge)")
            cursor = upper
        }
        let tail = SwiftUI.Text(AttributedString(text[cursor...]))
        return SwiftUI.Text("\(rendered)\(tail)")
    }

    private static func unique(_ sources: [ChatSource]) -> [ChatSource] {
        var seen: Set<URL> = []
        return sources.filter { seen.insert($0.url).inserted }
    }

    private static func isLabel(_ markup: any Markup) -> Bool {
        guard markup is Paragraph || markup is Heading,
              let text = markup as? any PlainTextConvertibleMarkup else { return false }
        return text.plainText.wholeMatch(of: /(?i)\s*sources:?\s*/) != nil
    }

    // Only replace a footer that consists entirely of source links and their separators.
    private static func read(_ paragraph: Paragraph, afterLabel: Bool = false) -> [Entry]? {
        var entries: [Entry] = []
        var prefix = ""
        for child in paragraph.children {
            if let link = child as? Markdown.Link {
                if afterLabel && entries.isEmpty {
                    guard let label = prefix.prefixMatch(of: /(?i)^\s*sources:\s*/) else { return nil }
                    prefix.removeSubrange(label.range)
                }
                guard let separator = prefix.wholeMatch(of: /[\s·•;,|]*(?:\[([0-9]+)\]\s*)?/),
                      let destination = link.destination, let url = URL(string: destination),
                      ChatLinks.isWebLink(url), url.host() != nil else { return nil }
                let number = separator.1.flatMap { Int($0) }
                if separator.1 != nil && number == nil { return nil }
                let title = link.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                entries.append(Entry(number: number, source: ChatSource(title: title, url: url)))
                prefix = ""
            } else if child is SoftBreak || child is LineBreak {
                prefix += " "
            } else if let text = child as? Markdown.Text {
                prefix += text.string
            } else if entries.isEmpty && afterLabel,
                      let styledLabel = child as? any PlainTextConvertibleMarkup,
                      child is Strong || child is Emphasis {
                prefix += styledLabel.plainText
            } else {
                return nil
            }
        }
        guard prefix.wholeMatch(of: /\s*\.?\s*/) != nil else { return nil }
        return entries
    }
}

private struct ChatCitationBadge: TextAttribute {}

struct ChatCitationRenderer: TextRenderer {
    func draw(layout: SwiftUI.Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                if run[ChatCitationBadge.self] != nil {
                    let bounds = run.typographicBounds.rect.insetBy(dx: 0, dy: -1)
                    context.fill(Capsule().path(in: bounds), with: .color(Color.secondary.opacity(0.2)))
                }
                context.draw(run)
            }
        }
    }
}

struct ChatSourceSelection: Identifiable {
    let id = UUID()
    let sources: [ChatSource]
}

struct ChatSourcesSheet: View {
    let sources: [ChatSource]
    let open: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(sources, id: \.url) { source in
                Button {
                    open(source.url)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "globe")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.title.isEmpty ? source.domain : source.title)
                                .font(.subheadline.weight(.medium))
                            Text(source.domain)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.right")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(.primary)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat-source")
            }
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
