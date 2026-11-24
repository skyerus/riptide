import Markdown
import RiptideCore
import SwiftUI

struct ChatMarkdown: View {
    let source: String
    var streaming = false

    var body: some View {
        let stream = MarkdownStreamSource(source, streaming: streaming)
        VStack(alignment: .leading, spacing: 4) {
            if !stream.committed.isEmpty {
                FormattedMarkdown(source: stream.committed, streaming: streaming).equatable()
            }
            if !stream.pending.isEmpty {
                Text(stream.pending)
                    .accessibilityIdentifier("markdown-live-tail")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineSpacing(3)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }
}

private struct FormattedMarkdown: View, Equatable {
    let source: String
    let streaming: Bool

    var body: some View {
        MarkdownBlocks(
            blocks: Array(Document(parsing: source).children),
            sourceLines: source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline),
            streaming: streaming
        )
    }
}

private struct MarkdownBlocks: View {
    let blocks: [any Markup]
    let sourceLines: [Substring]
    let streaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if let table = block as? Markdown.Table {
                    tableView(table)
                } else if let code = block as? CodeBlock {
                    let language = code.language?.split(whereSeparator: \.isWhitespace).first?.lowercased() ?? ""
                    if language == "mermaid", isClosed(code) {
                        DiagramPreview(source: code.code).id(code.code)
                    } else if language == "diff" || language == "patch" {
                        DiffPreview(source: code.code)
                    } else {
                        CodePreview(source: code.code, language: language, streaming: streaming && !isClosed(code))
                    }
                } else if let heading = block as? Heading {
                    inline(content(of: heading))
                        .font(heading.level == 1 ? .title3.weight(.semibold) : .headline)
                        .accessibilityAddTraits(.isHeader)
                } else if let paragraph = block as? Paragraph {
                    inline(content(of: paragraph))
                } else if let ordered = block as? OrderedList {
                    list(ordered, start: Int(ordered.startIndex))
                } else if let unordered = block as? UnorderedList {
                    list(unordered, start: nil)
                } else if let quote = block as? BlockQuote {
                    nested(quote)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            Capsule().fill(ChatTheme.border).frame(width: 3)
                        }
                } else if block is ThematicBreak {
                    Divider()
                } else {
                    inline(block.format().trimmingCharacters(in: .newlines))
                }
            }
        }
    }

    private func nested(_ block: any Markup) -> MarkdownBlocks {
        MarkdownBlocks(blocks: Array(block.children), sourceLines: sourceLines, streaming: streaming)
    }

    private func list(_ block: any Markup, start: Int?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(block.children.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let checkbox = (item as? ListItem)?.checkbox {
                        let checked = checkbox == .checked
                        Image(systemName: checked ? "checkmark.square" : "square")
                            .accessibilityLabel(checked ? "Done" : "Not done")
                    } else {
                        Text(start.map { "\($0 + index)." } ?? "•")
                            .monospacedDigit()
                            .accessibilityHidden(true)
                    }
                    nested(item)
                }
            }
        }
    }

    private func isClosed(_ code: CodeBlock) -> Bool {
        guard let range = code.range,
              range.lowerBound.line > 0,
              range.upperBound.line <= sourceLines.count,
              range.upperBound.line > range.lowerBound.line else { return false }
        let opener = sourceLines[range.lowerBound.line - 1]
        let leadingBytes = opener.utf8.dropFirst(max(0, range.lowerBound.column - 1))
        let openFence = Substring(String(decoding: leadingBytes, as: UTF8.self))
        let closer = sourceLines[range.upperBound.line - 1]
        guard MarkdownStreamSource.closesFence(opening: openFence, closing: closer) else { return false }
        let lastCodeLine = code.code.split(whereSeparator: \.isNewline).last
        return lastCodeLine?.trimmingCharacters(in: .whitespaces) != closer.trimmingCharacters(in: .whitespaces)
    }

    private func tableView(_ table: Markdown.Table) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        return ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 1, verticalSpacing: 1) {
                GridRow {
                    ForEach(Array(table.head.children.enumerated()), id: \.offset) { column, cell in
                        tableCell(cell, alignment: alignment(of: table, column: column))
                            .fontWeight(.semibold)
                            .background(ChatTheme.surface)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                ForEach(Array(table.body.children.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.children.enumerated()), id: \.offset) { column, cell in
                            tableCell(cell, alignment: alignment(of: table, column: column))
                                .background(ChatTheme.background)
                        }
                    }
                }
            }
            .background(ChatTheme.border)
            .clipShape(shape)
            .overlay { shape.strokeBorder(ChatTheme.border, lineWidth: 0.5) }
        }
        .accessibilityIdentifier("markdown-table")
    }

    private func tableCell(_ cell: any Markup, alignment: Alignment) -> some View {
        inline(content(of: cell))
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minWidth: 94, maxWidth: 230, alignment: alignment)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    private func alignment(of table: Markdown.Table, column: Int) -> Alignment {
        guard table.columnAlignments.indices.contains(column) else { return .leading }
        switch table.columnAlignments[column] {
        case .center: return .center
        case .right: return .trailing
        default: return .leading
        }
    }

    private func content(of markup: any Markup) -> String {
        markup.children.map { $0.format() }.joined()
    }

    private func inline(_ value: String) -> SwiftUI.Text {
        if let rich = try? AttributedString(
            markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            SwiftUI.Text(rich)
        } else {
            SwiftUI.Text(value)
        }
    }
}
