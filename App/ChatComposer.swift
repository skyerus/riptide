import RiptideCore
import SwiftUI

struct ChatComposer: View {
    let prompt: String
    let chatID: String?
    var fieldID = "chat-composer"
    @Binding var draft: String
    @Binding var modelPickerVisible: Bool
    var editorFocus: FocusState<Bool>.Binding
    var settings = ChatComposerSettings()
    var context: ContextUsage? = nil
    var ready = true
    let canDictate: Bool
    let canSubmit: Bool
    let transcribe: DictationTranscriber?
    var steering = false
    var stopping = false
    var stop: (() -> Void)? = nil
    let submit: () -> Void

    @State private var showContext = false

    var body: some View {
        VStack(spacing: 0) {
            if !modelPickerVisible, let error = settings.error {
                Text(error).font(.footnote).foregroundStyle(ChatTheme.warning)
                    .padding(.horizontal, ChatTheme.gutter)
            }
            DictatingComposer(
                focused: editorFocus.wrappedValue,
                showsOptions: context != nil || settings.hasChoices || settings.modelName != nil,
                chatID: chatID,
                canDictate: canDictate,
                draft: $draft,
                transcribe: transcribe,
                dismissKeyboard: {
                    editorFocus.wrappedValue = false
                    modelPickerVisible = false
                    showContext = false
                },
                canSubmit: canSubmit,
                submitDraft: submitDraft
            ) {
                TextField(prompt, text: $draft, prompt: Text(prompt).foregroundStyle(ChatTheme.muted), axis: .vertical)
                    .lineLimit(1...6)
                    .focused(editorFocus)
                    .disabled(!ready)
                    .accessibilityIdentifier(fieldID)
            } options: {
                if let context { contextButton(context) }
                ChatModelControls(settings: settings, isExpanded: $modelPickerVisible)
                FastModeButton(settings: settings)
            } actions: {
                actions
            }
        }
        .onChange(of: chatID) {
            showContext = false
            editorFocus.wrappedValue = false
        }
        .onChange(of: modelPickerVisible) {
            if modelPickerVisible { showContext = false }
        }
    }

    private func contextButton(_ usage: ContextUsage) -> some View {
        Button {
            modelPickerVisible = false
            showContext = true
        } label: {
            ZStack {
                Circle().strokeBorder(ChatTheme.border, lineWidth: 2)
                Circle().trim(from: 0, to: usage.fraction)
                    .stroke(ChatTheme.sidebarAccent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 17, height: 17)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Context window")
        .accessibilityValue(usage.fraction.formatted(.percent.precision(.fractionLength(0))) + " used")
        .accessibilityIdentifier("context-usage")
        .popover(isPresented: $showContext, arrowEdge: .bottom) {
            if let current = context {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Context window").font(.headline)
                    Text("\(current.used.formatted()) of \(current.capacity.formatted()) tokens used")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("context-values")
                }
                .padding(16)
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    private func submitDraft() {
        guard canSubmit, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        editorFocus.wrappedValue = false
        modelPickerVisible = false
        submit()
    }

    @ViewBuilder private var actions: some View {
        if let stop {
            ComposerAction(steering ? "Stop turn" : "Stop reply", symbol: "stop.fill", disabled: stopping, action: stop)
                .accessibilityIdentifier(steering ? "stop-codex-turn" : "stop-reply")
        }
        if steering || stop == nil {
            ComposerAction(steering ? "Steer" : "Send", symbol: "arrow.up",
                           disabled: !canSubmit || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           action: submitDraft)
                .accessibilityIdentifier(steering ? "codex-steer-send" : "send-message")
        }
    }
}

struct ComposerSurface<Field: View, Options: View, Actions: View>: View {
    let focused: Bool
    let showsOptions: Bool
    private let field: Field
    private let options: Options
    private let actions: Actions

    init(focused: Bool, showsOptions: Bool, @ViewBuilder field: () -> Field,
         @ViewBuilder options: () -> Options, @ViewBuilder actions: () -> Actions) {
        self.focused = focused
        self.showsOptions = showsOptions
        self.field = field()
        self.options = options()
        self.actions = actions()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26)
        let layout = showsOptions ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: 8))
        layout {
            field
                .font(.body)
                .foregroundStyle(ChatTheme.ink)
                .tint(ChatTheme.ink)
                .padding(.leading, 15)
                .padding(.trailing, showsOptions ? 15 : 0)
                .padding(.vertical, showsOptions ? 8 : 10)
                .frame(minHeight: 44, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 1) {
                if showsOptions {
                    options
                    Spacer(minLength: 4)
                }
                actions
            }
            .padding(.leading, showsOptions ? 4 : 0)
            .padding(.trailing, 4)
        }
        .padding(.vertical, 3)
        .chatGlass(in: shape, focused: focused)
        .frame(maxWidth: ChatTheme.readingWidth)
        .padding(.horizontal, ChatTheme.gutter)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}

extension View {
    @ViewBuilder
    func chatGlass(in shape: some InsettableShape, focused: Bool = false) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.tint(ChatTheme.background.opacity(0.30)), in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(focused ? ChatTheme.muted.opacity(0.5) : ChatTheme.sidebarDivider)
                        .allowsHitTesting(false)
                }
        }
    }
}

struct ComposerAction: View {
    let title: String
    let symbol: String
    let disabled: Bool
    let action: () -> Void

    init(_ title: String, symbol: String, disabled: Bool, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "stop.fill" ? 11 : 16, weight: .semibold))
                .foregroundStyle(disabled ? ChatTheme.muted : ChatTheme.background)
                .frame(width: 34, height: 34)
                .background(disabled ? ChatTheme.raised : ChatTheme.ink, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(title)
    }
}
