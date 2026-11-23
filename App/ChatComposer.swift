import RiptideCore
import SwiftUI

struct ChatComposer: View {
    let model: AgentChatModel
    @Binding var draft: String
    let didSend: () -> Void

    @State private var showModels = false
    @State private var showContext = false

    private var modelName: String? {
        model.selected.configOptions.first(where: { $0.category == .model })?.currentName
    }

    private var effortName: String? {
        model.selected.configOptions.first(where: { $0.category == .thoughtLevel })?.currentName
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22)
        VStack(alignment: .leading, spacing: 0) {
            TextField("Message \(model.target.name)", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .padding(.horizontal, 15)
                .padding(.top, 13)
                .padding(.bottom, 4)
                .disabled(!model.selected.loaded)
                .accessibilityIdentifier("chat-composer")
            HStack(spacing: 2) {
                if let usage = model.selected.context {
                    contextButton(usage)
                }
                if !model.selected.configOptions.isEmpty {
                    modelButton
                }
                Spacer(minLength: 4)
                actionButton
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 3)
        }
        .background(ChatTheme.surface, in: shape)
        .overlay { shape.strokeBorder(ChatTheme.border, lineWidth: 0.5).allowsHitTesting(false) }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(ChatTheme.background)
        .sheet(isPresented: $showModels) {
            ModelPicker(model: model, sessionID: model.selectedID)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: model.selectedID) {
            showModels = false
            showContext = false
        }
    }

    private var modelButton: some View {
        let title = modelName ?? effortName ?? "Model options"
        let subtitle = modelName == nil ? nil : effortName
        return Button {
            showModels = true
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .layoutPriority(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model and effort")
        .accessibilityValue([title, subtitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("model-options")
    }

    private func contextButton(_ usage: ContextUsage) -> some View {
        Button {
            showContext = true
        } label: {
            ZStack {
                Circle().strokeBorder(ChatTheme.border, lineWidth: 2)
                Circle().trim(from: 0, to: usage.fraction)
                    .stroke(ChatTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
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
        return Button {
            if working {
                Task { await model.stop() }
            } else {
                model.submit(draft)
                draft = ""
                didSend()
            }
        } label: {
            Image(systemName: working ? "stop.fill" : "arrow.up")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
                .foregroundStyle(disabled ? Color.secondary : ChatTheme.background)
                .background(disabled ? ChatTheme.inset : ChatTheme.accent, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(working ? "Stop reply" : "Send")
        .accessibilityIdentifier(working ? "stop-reply" : "send-message")
    }
}

private struct ModelPicker: View {
    let model: AgentChatModel
    let sessionID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.selected.configOptions) { option in
                    Section(option.name) {
                        ForEach(option.choices) { choice in
                            Button {
                                Task { await model.setConfigOption(option.id, value: choice.id, sessionID: sessionID) }
                            } label: {
                                HStack {
                                    Text(choice.name)
                                    Spacer()
                                    if option.currentValue == choice.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(ChatTheme.accent)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .frame(minHeight: 32)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(option.currentValue == choice.id ? .isSelected : [])
                            .accessibilityIdentifier("config-\(option.id)-\(choice.id)")
                        }
                    }
                    .disabled(model.selected.working || model.selected.configuring)
                }
                if let error = model.selected.configError {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                } else if model.selected.working {
                    Text("You can change these after the reply finishes.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Model & effort")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
