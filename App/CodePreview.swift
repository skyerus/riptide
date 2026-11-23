import JavaScriptCore
import RiptideCore
import SwiftUI

struct CodePreview: View {
    let source: String
    let language: String
    var streaming = false

    @State private var highlighted: HighlightResult?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "Code" : language)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = source
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "document.on.document")
                        .font(.caption)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("copy-code")
            }
            .padding(.horizontal, 12)
            Divider()
            ScrollView(.horizontal) {
                Text(highlighted?.source == source && highlighted?.language == language
                     ? highlighted?.text ?? AttributedString(source) : AttributedString(source))
                    .font(.system(.footnote, design: .monospaced))
                    .lineSpacing(4)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(12)
                    .textSelection(.enabled)
            }
        }
        .contentPanel()
        .task(id: HighlightRequest(source: source, language: language, streaming: streaming)) {
            copied = false
            if streaming { try? await Task.sleep(for: .milliseconds(100)) }
            guard !Task.isCancelled else { return }
            highlighted = NativeHighlighter.highlight(source, language: language)
                .map { HighlightResult(source: source, language: language, text: $0) }
        }
    }

    private struct HighlightResult {
        let source: String
        let language: String
        let text: AttributedString
    }

    private struct HighlightRequest: Equatable {
        let source: String
        let language: String
        let streaming: Bool
    }
}

struct DiffPreview: View {
    let source: String
    var title = "Diff"
    @State private var copied = false

    var body: some View {
        let diff = UnifiedDiff(source)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "plus.forwardslash.minus").accessibilityHidden(true)
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text("+\(diff.additions)").foregroundStyle(ChatTheme.accent)
                Text("−\(diff.deletions)").foregroundStyle(Color(red: 1, green: 0.57, blue: 0.65))
                Button {
                    UIPasteboard.general.string = source
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "document.on.document")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Copied diff" : "Copy diff")
            }
            .font(.caption.monospacedDigit())
            .padding(.leading, 12)
            Divider()
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                            HStack(spacing: 0) {
                                number(line.oldNumber)
                                number(line.newNumber)
                                Text(line.text.replacingOccurrences(of: "\t", with: "    "))
                                    .fixedSize()
                                    .padding(.horizontal, 8)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3)
                            .foregroundStyle(foreground(line.kind))
                            .background(background(line.kind))
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .frame(minWidth: geometry.size.width)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.vertical, 4)
                }
            }
            .frame(height: min(CGFloat(diff.lines.count * 23 + 8), 328))
            .textSelection(.enabled)
            if diff.truncated {
                Divider()
                Text("Preview only. Copy diff for the full patch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
        .contentPanel()
        .accessibilityIdentifier("markdown-diff")
        .onChange(of: source) { copied = false }
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(.secondary)
            .frame(minWidth: 32, alignment: .trailing)
            .padding(.trailing, 5)
            .accessibilityHidden(true)
    }

    private func foreground(_ kind: UnifiedDiff.Kind) -> Color {
        switch kind {
        case .addition: Color(red: 0.66, green: 0.93, blue: 0.78)
        case .deletion: Color(red: 1, green: 0.69, blue: 0.73)
        case .hunk: Color(red: 0.68, green: 0.77, blue: 1)
        case .file: .secondary
        default: .primary
        }
    }

    private func background(_ kind: UnifiedDiff.Kind) -> Color {
        switch kind {
        case .addition: Color.green.opacity(0.12)
        case .deletion: Color.red.opacity(0.15)
        case .hunk: Color.blue.opacity(0.10)
        default: .clear
        }
    }
}

extension View {
    func contentPanel() -> some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        return background(ChatTheme.surface, in: shape)
            .clipShape(shape)
            .overlay { shape.strokeBorder(ChatTheme.border, lineWidth: 0.5).allowsHitTesting(false) }
    }
}

@MainActor
private enum NativeHighlighter {
    private static let context: JSContext? = {
        guard let url = Bundle.main.url(forResource: "highlight", withExtension: "js", subdirectory: "RichContent"),
              let script = try? String(contentsOf: url, encoding: .utf8),
              let context = JSContext() else { return nil }
        context.evaluateScript(script)
        return context
    }()

    static func highlight(_ text: String, language: String) -> AttributedString? {
        guard !language.isEmpty, text.utf8.count <= 24_000,
              let value = context?.objectForKeyedSubscript("highlightCode")?.call(withArguments: [text, language]),
              !value.isNull, !value.isUndefined, let html = value.toString() else { return nil }
        let delegate = HighlightSpans()
        let parser = XMLParser(data: Data("<root>\(html)</root>".utf8))
        parser.delegate = delegate
        return parser.parse() ? delegate.output : nil
    }
}

private final class HighlightSpans: NSObject, XMLParserDelegate {
    var output = AttributedString()
    private var colors: [Color?] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        let scopes = Set((attributes["class"] ?? "").split(separator: " "))
        let color: Color?
        if !scopes.isDisjoint(with: ["hljs-comment", "hljs-quote"]) {
            color = Color(red: 0.57, green: 0.63, blue: 0.68)
        } else if !scopes.isDisjoint(with: ["hljs-keyword", "hljs-selector-tag", "hljs-meta"]) {
            color = Color(red: 0.85, green: 0.69, blue: 1)
        } else if !scopes.isDisjoint(with: ["hljs-string", "hljs-regexp", "hljs-addition"]) {
            color = Color(red: 0.67, green: 0.89, blue: 0.67)
        } else if !scopes.isDisjoint(with: ["hljs-number", "hljs-literal", "hljs-deletion"]) {
            color = Color(red: 1, green: 0.75, blue: 0.57)
        } else if !scopes.isDisjoint(with: ["hljs-title", "hljs-type", "hljs-built_in", "hljs-attr"]) {
            color = Color(red: 0.60, green: 0.83, blue: 1)
        } else {
            color = nil
        }
        colors.append(color ?? colors.last.flatMap { $0 })
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        var token = AttributedString(string)
        token.foregroundColor = colors.last.flatMap { $0 }
        output.append(token)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        _ = colors.popLast()
    }
}
