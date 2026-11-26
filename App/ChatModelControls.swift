import RiptideCore
import SwiftUI

struct ChatComposerSettings {
    var options: [SessionConfigOption] = []
    var reportedModelName: String? = nil
    var configuring = false
    var working = false
    var error: String? = nil
    var select: (String, String) async -> Bool = { _, _ in false }

    var modelName: String? { options.first { $0.category == .model }?.currentName ?? reportedModelName }
    var hasChoices: Bool { options.contains { !$0.pickerChoices.isEmpty } }
}

struct ChatModelControls: View {
    let settings: ChatComposerSettings
    @Binding var isExpanded: Bool

    var body: some View {
        let summary = ModelSelectionSummary(settings: settings)
        if settings.hasChoices {
            Button {
                isExpanded.toggle()
            } label: {
                ModelSelectionLabel(summary: summary, chevron: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.subheadline)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Model and intelligence")
            .accessibilityValue(summary.accessibilityValue)
            .accessibilityIdentifier("model-options")
        } else if let name = settings.modelName {
            Text(name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(minHeight: 44)
                .accessibilityIdentifier("current-model")
        }
    }
}

struct FastModeButton: View {
    let settings: ChatComposerSettings

    var body: some View {
        if let option = settings.options.first(where: { $0.fastMode != nil }),
           let enabled = option.fastMode, let standard = option.standardSpeedID {
            Button {
                Task { await settings.select(option.id, enabled ? standard : "fast") }
            } label: {
                Image(systemName: enabled ? "bolt.fill" : "bolt")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(enabled ? ChatTheme.sidebarAccent : ChatTheme.muted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(settings.configuring || settings.working)
            .accessibilityLabel("Fast mode")
            .accessibilityValue(enabled ? "On" : "Off")
            .accessibilityAddTraits(enabled ? .isSelected : [])
            .accessibilityIdentifier("fast-mode")
        }
    }
}

struct ChatModelPicker: ViewModifier {
    let settings: ChatComposerSettings
    let composerHeight: CGFloat
    let chatID: String?
    @Binding var isExpanded: Bool
    @State private var showAdvanced = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let visible = isExpanded && settings.hasChoices
        content
            .overlay(alignment: .bottom) {
                if visible {
                    ZStack(alignment: .bottom) {
                        Button { isExpanded = false } label: {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss model controls")
                        .accessibilityIdentifier("dismiss-model-picker")

                        QuickModelPicker(settings: settings) {
                            isExpanded = false
                            showAdvanced = true
                        }
                        .padding(.bottom, 4)
                    }
                    .padding(.bottom, composerHeight)
                    .transition(.opacity)
                    .accessibilityAction(.escape) { isExpanded = false }
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: visible)
            .sheet(isPresented: $showAdvanced) {
                AdvancedModelPicker(settings: settings)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.regularMaterial)
            }
            .onChange(of: chatID) {
                isExpanded = false
                showAdvanced = false
            }
    }
}

private struct ModelSelectionSummary {
    let title: String
    let intelligence: String?
    var accessibilityValue: String { [title, intelligence].compactMap { $0 }.joined(separator: ", ") }

    init(settings: ChatComposerSettings) {
        let effort = settings.options.first { $0.category == .thoughtLevel }?.currentName
        title = settings.modelName ?? effort ?? "Model options"
        intelligence = settings.modelName == nil ? nil : effort
    }
}

private struct ModelSelectionLabel: View {
    let summary: ModelSelectionSummary
    let chevron: String

    var body: some View {
        HStack(spacing: 5) {
            Text(summary.title)
                .fontWeight(.semibold)
                .lineLimit(1)
                .accessibilityHidden(true)
            if let intelligence = summary.intelligence {
                Text(intelligence)
                    .foregroundStyle(ChatTheme.muted)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .accessibilityHidden(true)
            }
            Image(systemName: chevron)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ChatTheme.muted)
                .accessibilityHidden(true)
        }
    }
}

struct QuickModelPicker: View {
    let settings: ChatComposerSettings
    let showAdvanced: () -> Void

    var body: some View {
        let summary = ModelSelectionSummary(settings: settings)
        VStack(spacing: 5) {
            Button(action: showAdvanced) {
                ModelSelectionLabel(summary: summary, chevron: "chevron.right")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Advanced")
            .accessibilityValue(summary.accessibilityValue)
            .accessibilityIdentifier("advanced-model-controls")

            if let effort = settings.options.first(where: { $0.category == .thoughtLevel }) {
                let choices = effort.pickerChoices
                if (2...10).contains(choices.count) {
                    IntelligenceSteps(option: effort, choices: choices) { choice in
                        Task { await settings.select(effort.id, choice.id) }
                    }
                    .disabled(settings.configuring || settings.working)
                }
            }
            ModelControlStatus(settings: settings)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 340)
        .chatGlass(in: RoundedRectangle(cornerRadius: 26))
        .padding(.horizontal, ChatTheme.gutter)
    }
}

private struct IntelligenceSteps: View {
    let option: SessionConfigOption
    let choices: [SessionConfigOption.Choice]
    let select: (SessionConfigOption.Choice) -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var preview: Int? = nil
    private let trackHeight: CGFloat = 54
    private let trackInset: CGFloat = 5

    private var active: Int? { choices.firstIndex { $0.id == option.currentValue } }

    var body: some View {
        GeometryReader { geometry in
            let thumb = min(trackHeight - trackInset * 2, max(0, geometry.size.width - trackInset * 2))
            let start = trackInset + thumb / 2
            let step = max(0, geometry.size.width - start * 2) / CGFloat(choices.count - 1)
            let center: (Int) -> CGFloat = { start + CGFloat($0) * step }
            let selected = preview ?? active
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .overlay { Capsule().strokeBorder(.white.opacity(0.08)) }
                if let selected {
                    Capsule().fill(ChatTheme.ink)
                        .frame(width: center(selected) + thumb / 2 - trackInset, height: thumb)
                        .offset(x: trackInset)
                }
                ForEach(choices.indices, id: \.self) { index in
                    if index != selected {
                        Circle().fill(index < (selected ?? 0) ? .black.opacity(0.22) : .white.opacity(0.30))
                            .frame(width: 8, height: 8)
                            .offset(x: center(index) - 4)
                    }
                }
                if let selected {
                    Circle().fill(.white)
                        .overlay { Circle().strokeBorder(.black.opacity(0.07)) }
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                        .frame(width: thumb, height: thumb)
                        .offset(x: center(selected) - thumb / 2)
                }
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($preview) { value, preview, _ in
                    if isEnabled { preview = index(at: value.location.x, start: start, step: step) }
                }
                .onEnded { value in
                    if isEnabled, let index = index(at: value.location.x, start: start, step: step) {
                        select(choices[index])
                    }
                }
            )
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: selected)
        }
        .frame(height: trackHeight)
        .opacity(isEnabled ? 1 : 0.6)
        .overlay {
            if let preview, preview != active, choices.indices.contains(preview) {
                Text(choices[preview].name)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(ChatTheme.background, in: Capsule())
                    .offset(y: -34)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Intelligence")
        .accessibilityValue(option.currentName ?? "Agent default")
        .accessibilityIdentifier("intelligence-steps")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            let index = active ?? -1
            switch direction {
            case .increment:
                if choices.indices.contains(index + 1) { select(choices[index + 1]) }
            case .decrement:
                if choices.indices.contains(index - 1) { select(choices[index - 1]) }
            @unknown default: break
            }
        }
    }

    private func index(at position: CGFloat, start: CGFloat, step: CGFloat) -> Int? {
        guard step > 0 else { return nil }
        return Int(min(max(0, ((position - start) / step).rounded()), CGFloat(choices.count - 1)))
    }
}

struct AdvancedModelPicker: View {
    let settings: ChatComposerSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(settings.options.filter { !$0.pickerChoices.isEmpty }) { option in
                        NavigationLink(value: option.id) {
                            HStack(spacing: 12) {
                                Text(option.pickerTitle)
                                Spacer(minLength: 4)
                                Text(option.currentName ?? "Agent default")
                                    .foregroundStyle(ChatTheme.muted)
                                    .lineLimit(1)
                            }
                        }
                        .accessibilityLabel(option.pickerTitle)
                        .accessibilityValue(option.currentName ?? "")
                        .accessibilityIdentifier("config-picker-\(option.id)")
                    }
                }
                ModelControlStatus(settings: settings)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Advanced")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(for: String.self) { optionID in
                ModelOptionChoices(settings: settings, optionID: optionID)
            }
        }
    }
}

private struct ModelOptionChoices: View {
    let settings: ChatComposerSettings
    let optionID: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        if let option = settings.options.first(where: { $0.id == optionID }) {
            if option.category == .model && option.choices.count > 8 {
                choiceList(option).searchable(text: $search, prompt: "Find a model")
            } else {
                choiceList(option)
            }
        } else {
            ContentUnavailableView("Setting unavailable", systemImage: "slider.horizontal.3")
        }
    }

    private func choiceList(_ option: SessionConfigOption) -> some View {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let choices = option.pickerChoices.filter {
            query.isEmpty || [$0.name, $0.id, $0.group].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        let groups = Dictionary(grouping: choices, by: \.group)
        var seen = Set<String?>()
        let groupOrder = choices.map(\.group).filter { seen.insert($0).inserted }
        return List {
            ModelControlStatus(settings: settings)
            ForEach(groupOrder, id: \.self) { group in
                Section {
                    ForEach(groups[group] ?? []) { choice in
                        choiceRow(choice, option: option)
                    }
                } header: {
                    if let group { Text(group).textCase(nil) }
                }
            }
            if choices.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(option.pickerTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choiceRow(_ choice: SessionConfigOption.Choice, option: SessionConfigOption) -> some View {
        let selected = option.currentValue == choice.id
        return Button {
            guard !selected else { dismiss(); return }
            Task {
                if await settings.select(option.id, choice.id) { dismiss() }
            }
        } label: {
            HStack {
                Text(choice.name)
                Spacer()
                if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(settings.configuring || settings.working)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("config-\(option.id)-\(choice.id)")
    }
}

private struct ModelControlStatus: View {
    let settings: ChatComposerSettings

    var body: some View {
        if settings.configuring {
            ProgressView("Updating…").font(.footnote)
        } else if let error = settings.error {
            Text(error).font(.footnote).foregroundStyle(ChatTheme.warning)
        } else if settings.working {
            Text("Changes are available after the reply finishes.")
                .font(.footnote)
                .foregroundStyle(ChatTheme.muted)
        }
    }
}

private extension SessionConfigOption {
    var pickerTitle: String {
        switch category {
        case .thoughtLevel: "Intelligence"
        case .serviceTier: "Speed"
        case .model: name
        }
    }

    var pickerChoices: [Choice] {
        guard category == .thoughtLevel else { return choices }
        return choices.filter { !["none", "minimal"].contains($0.id.lowercased()) }
    }
}
