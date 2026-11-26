import RiptideCore
import SwiftUI

struct ChatComposer: View {
    let model: AgentChatModel
    let chatID: String
    @Binding var draft: String
    @Binding var modelPickerVisible: Bool
    var editorFocus: FocusState<Bool>.Binding
    let transcribe: DictationTranscriber?
    let didSend: () -> Void
    let submit: (String) -> Bool

    @State private var showContext = false

    var body: some View {
        let working = model.selected.working
        let prompt = working ? "Steer this reply" : "Message \(model.target.name)"
        let queue: (() -> Void)? = working ? { submitDraft(queue: true) } : nil
        DictatingComposer(
            focused: editorFocus.wrappedValue,
            showsOptions: model.selected.context != nil || model.selected.hasConfigChoices
                || model.selected.modelName != nil,
            chatID: chatID,
            canDictate: model.selected.loaded,
            draft: $draft,
            transcribe: transcribe,
            dismissKeyboard: {
                editorFocus.wrappedValue = false
                modelPickerVisible = false
                showContext = false
            },
            canSubmit: canSubmit,
            submitDraft: { submitDraft(queue: false) },
            queueDraft: queue
        ) {
            TextField(prompt, text: $draft, prompt: Text(prompt).foregroundStyle(ChatTheme.muted), axis: .vertical)
                .lineLimit(1...6)
                .focused(editorFocus)
                .disabled(!model.selected.loaded)
                .accessibilityIdentifier("chat-composer")
        } options: {
            if let usage = model.selected.context {
                contextButton(usage)
            }
            ChatModelControls(model: model, isExpanded: $modelPickerVisible)
        } actions: {
            if working {
                ComposerAction("Stop reply", symbol: "stop.fill", disabled: model.selected.stopping) {
                    Task { await model.stop() }
                }
                .accessibilityIdentifier("stop-reply")
            }
            ComposerAction(working ? "Steer" : "Send", symbol: "arrow.up",
                           disabled: !canSubmit || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           queue: queue) {
                submitDraft(queue: false)
            }
            .accessibilityIdentifier("send-message")
        }
        .onChange(of: model.selectedID) {
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

    private var canSubmit: Bool {
        model.selectedID == chatID && model.selected.loaded &&
            !model.selected.loading && !model.selected.configuring && !model.selected.stopping && !model.selected.steering
    }

    private func submitDraft(queue: Bool) {
        let editor = $draft
        let text = editor.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmit, !text.isEmpty else { return }
        editorFocus.wrappedValue = false
        didSend()
        if queue {
            if model.enqueue(text, in: chatID) { editor.wrappedValue = "" }
        } else if model.selected.working {
            Task {
                if await model.steer(text, in: chatID),
                   editor.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                    editor.wrappedValue = ""
                }
            }
        } else if submit(text) {
            editor.wrappedValue = ""
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
    let queue: (() -> Void)?
    let action: () -> Void
    @State private var showingQueueOptions = false
    @State private var queueSelection: (() -> Void)?

    init(_ title: String, symbol: String, disabled: Bool, queue: (() -> Void)? = nil,
         action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.disabled = disabled
        self.queue = queue
        self.action = action
    }

    var body: some View {
        button
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                guard let queue, !disabled else { return }
                queueSelection = queue
                showingQueueOptions = true
            }, including: queue != nil && !disabled ? .all : .none)
            .popover(isPresented: $showingQueueOptions, arrowEdge: .bottom) {
                Button("Queue", systemImage: "text.append") {
                    let selection = queueSelection
                    showingQueueOptions = false
                    selection?()
                }
                .foregroundStyle(ChatTheme.ink)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .presentationCompactAdaptation(.popover)
                .accessibilityIdentifier("queue-follow-up")
            }
            .onChange(of: showingQueueOptions) { if !showingQueueOptions { queueSelection = nil } }
            .accessibilityHint(queue == nil ? Text("") : Text("Touch and hold for Queue."))
            .accessibilityActions {
                if let queue, !disabled { Button("Queue", action: queue) }
            }
    }

    private var button: some View {
        Button {
            if !showingQueueOptions { action() }
        } label: {
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

struct ComposerQueue: View {
    let messages: [QueuedChatMessage]
    let sendingID: UUID?
    let paused: Bool
    let canResume: Bool
    let remove: (UUID) -> Void
    let resume: () -> Void
    @State private var showingMessages = false

    var body: some View {
        if !messages.isEmpty {
            HStack {
                Button {
                    showingMessages = true
                } label: {
                    Label("\(messages.count) queued", systemImage: "text.append")
                        .monospacedDigit()
                }
                .accessibilityIdentifier("queued-messages")
                .popover(isPresented: $showingMessages, arrowEdge: .bottom) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(messages) { message in
                                HStack(spacing: 12) {
                                    Text(message.text).lineLimit(3)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if sendingID == message.id {
                                        ProgressView()
                                    } else {
                                        Button(role: .destructive) {
                                            remove(message.id)
                                            if messages.count == 1 { showingMessages = false }
                                        } label: {
                                            Label("Remove queued message", systemImage: "xmark")
                                                .labelStyle(.iconOnly)
                                                .frame(width: 44, height: 44)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.leading, 16)
                        .padding(.trailing, 4)
                    }
                    .frame(width: 280)
                    .frame(height: CGFloat(min(messages.count, 4)) * 48)
                    .font(.subheadline)
                    .presentationCompactAdaptation(.popover)
                }
                if paused {
                    Spacer(minLength: 8)
                    Button("Resume queue", action: resume).disabled(!canResume)
                }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(ChatTheme.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .chatGlass(in: Capsule())
            .frame(maxWidth: ChatTheme.readingWidth, alignment: .leading)
            .padding(.horizontal, ChatTheme.gutter)
        }
    }
}
