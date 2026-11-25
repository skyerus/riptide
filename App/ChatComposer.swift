import RiptideCore
import SwiftUI

struct ChatComposer: View {
    let model: AgentChatModel
    @Binding var draft: String
    @Binding var modelPickerVisible: Bool
    let didSend: () -> Void

    @State private var showContext = false
    @FocusState private var editorFocused: Bool

    var body: some View {
        let prompt = "Message \(model.target.name)"
        ComposerSurface(focused: editorFocused,
                        showsOptions: model.selected.context != nil || model.selected.hasConfigChoices
                            || model.selected.modelName != nil) {
            TextField(prompt, text: $draft, prompt: Text(prompt).foregroundStyle(ChatTheme.muted), axis: .vertical)
                .lineLimit(1...6)
                .focused($editorFocused)
                .disabled(!model.selected.loaded)
                .accessibilityIdentifier("chat-composer")
        } options: {
            if let usage = model.selected.context {
                contextButton(usage)
            }
            ChatModelControls(model: model, isExpanded: $modelPickerVisible)
        } actions: {
            actionButton
        }
        .onChange(of: model.selectedID) {
            showContext = false
            editorFocused = false
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
            if let current = model.selected.context {
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

    private var actionButton: some View {
        let working = model.selected.working
        let disabled = working ? model.selected.stopping : !model.selected.loaded || model.selected.configuring
            || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return ComposerAction(working ? "Stop reply" : "Send", symbol: working ? "stop.fill" : "arrow.up",
                              disabled: disabled) {
            if working {
                Task { await model.stop() }
            } else {
                model.submit(draft)
                draft = ""
                editorFocused = false
                didSend()
            }
        }
        .accessibilityIdentifier(working ? "stop-reply" : "send-message")
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

extension ComposerSurface where Options == EmptyView {
    init(focused: Bool, @ViewBuilder field: () -> Field, @ViewBuilder actions: () -> Actions) {
        self.init(focused: focused, showsOptions: false, field: field, options: { EmptyView() }, actions: actions)
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
