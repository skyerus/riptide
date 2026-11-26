import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ComposerEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let prompt: String
    let identifier: String
    let enabled: Bool
    let pasteAttachments: ([NSItemProvider]) -> Void

    func makeUIView(context: Context) -> PasteTextView {
        let view = PasteTextView()
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
        return view
    }

    func updateUIView(_ view: PasteTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.editor = self
        view.pasteAttachments = pasteAttachments
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

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PasteTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, let lineHeight = uiView.font?.lineHeight else { return nil }
        let measured = uiView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: width, height: min(ceil(lineHeight * 6), max(ceil(lineHeight), measured.height)))
    }

    func makeCoordinator() -> Coordinator { Coordinator(editor: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var editor: ComposerEditor

        init(editor: ComposerEditor) { self.editor = editor }

        func textViewDidChange(_ textView: UITextView) {
            editor.text = textView.text
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ textView: UITextView) { editor.focused = true }

        func textViewDidEndEditing(_ textView: UITextView) { editor.focused = false }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard textView.isEditable, ClipboardAttachment.isOnPasteboard,
                  !suggestedActions.contains(where: Self.isPasteAction) else { return nil }
            let paste = UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak textView] _ in
                textView?.paste(nil)
            }
            return UIMenu(children: [paste] + suggestedActions)
        }

        private static func isPasteAction(_ element: UIMenuElement) -> Bool {
            if let command = element as? UICommand { return command.action == #selector(UIResponder.paste(_:)) }
            if let menu = element as? UIMenu { return menu.children.contains(where: isPasteAction) }
            return false
        }
    }

    final class PasteTextView: UITextView {
        var pasteAttachments: (([NSItemProvider]) -> Void)?

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(paste(_:)), isEditable, ClipboardAttachment.isOnPasteboard { return true }
            return super.canPerformAction(action, withSender: sender)
        }

        override func paste(_ sender: Any?) {
            guard isEditable else { return }
            let clipboard = UIPasteboard.general
            guard ClipboardAttachment.isOnPasteboard || clipboard.numberOfItems > 1 else { return super.paste(sender) }

            let providers = clipboard.itemProviders
            let attachments = providers.filter { ClipboardAttachment.type(in: $0) != nil }
            guard !attachments.isEmpty else { return super.paste(sender) }
            pasteAttachments?(attachments)

            let textItems = providers.filter { ClipboardAttachment.type(in: $0) == nil }
            if !textItems.isEmpty { super.paste(itemProviders: textItems) }
        }
    }
}

@MainActor
enum ClipboardAttachment {
    static var isOnPasteboard: Bool {
        let clipboard = UIPasteboard.general
        return clipboard.hasImages || type(from: clipboard.types) != nil
    }

    static func type(in provider: NSItemProvider) -> UTType? { type(from: provider.registeredTypeIdentifiers) }

    private static func type(from identifiers: [String]) -> UTType? {
        let types = identifiers.compactMap(UTType.init)
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
