import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ComposerEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let prompt: String
    let identifier: String
    let enabled: Bool
    let pasteAttachments: (NSItemProvider) -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.textColor = UIColor(ChatTheme.ink)
        view.tintColor = UIColor(ChatTheme.ink)
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = identifier
        view.accessibilityLabel = prompt
        view.delegate = context.coordinator
        view.pasteDelegate = context.coordinator
        view.pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.item.identifier])
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.editor = self
        if view.text != text, view.markedTextRange == nil { view.text = text }
        view.isEditable = enabled
        guard view.isFirstResponder != (enabled && focused) else { return }
        Task { @MainActor [weak view, weak coordinator] in
            guard let view, view.window != nil, let editor = coordinator?.editor else { return }
            if editor.enabled && editor.focused {
                if !view.isFirstResponder { view.becomeFirstResponder() }
            } else if view.isFirstResponder {
                view.resignFirstResponder()
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, let lineHeight = uiView.font?.lineHeight else { return nil }
        let measured = uiView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: width, height: min(ceil(lineHeight * 6), max(ceil(lineHeight), measured.height)))
    }

    func makeCoordinator() -> Coordinator { Coordinator(editor: self) }

    final class Coordinator: NSObject, UITextViewDelegate, UITextPasteDelegate {
        var editor: ComposerEditor

        init(editor: ComposerEditor) { self.editor = editor }

        func textViewDidChange(_ textView: UITextView) {
            editor.text = textView.text
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ textView: UITextView) { editor.focused = true }

        func textViewDidEndEditing(_ textView: UITextView) { editor.focused = false }

        func textPasteConfigurationSupporting(_ supporting: any UITextPasteConfigurationSupporting,
                                              transform item: any UITextPasteItem) {
            let provider = item.itemProvider
            if ClipboardAttachment.type(in: provider) != nil {
                editor.pasteAttachments(provider)
                item.setNoResult()
            } else {
                item.setDefaultResult()
            }
        }
    }
}

enum ClipboardAttachment {
    static func type(in provider: NSItemProvider) -> UTType? {
        let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        if let image = types.first(where: { $0.conforms(to: .image) }) { return image }
        let file = types.first { $0.conforms(to: .data) && !$0.conforms(to: .text) && !$0.conforms(to: .url) }
        if types.contains(.fileURL) { return file == nil || file == .data ? .fileURL : file }
        // Let UIKit insert pasted text, rich text, and ordinary URLs at the caret.
        if types.contains(where: { $0.conforms(to: .text) || $0.conforms(to: .url) }) { return nil }
        return file
    }

    static func filename(for provider: NSItemProvider, type: UTType) -> String {
        let name = provider.suggestedName ?? (type.conforms(to: .image) ? "Pasted photo" : "Pasted file")
        guard (name as NSString).pathExtension.isEmpty, let suffix = type.preferredFilenameExtension else { return name }
        return name + "." + suffix
    }
}
