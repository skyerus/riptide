import RiptideCore
import SwiftUI

struct ChatModelControls: View {
    let model: AgentChatModel
    @Binding var isExpanded: Bool

    var body: some View {
        let summary = ModelSelectionSummary(options: model.selected.configOptions)
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
    }
}

private struct ModelSelectionSummary {
    let title: String
    let intelligence: String?
    var accessibilityValue: String { [title, intelligence].compactMap { $0 }.joined(separator: ", ") }

    init(options: [SessionConfigOption]) {
        let model = options.first { $0.category == .model }
        let effort = options.first { $0.category == .thoughtLevel }?.currentName
        title = model.map { $0.currentName ?? "Model" } ?? effort ?? "Model options"
        intelligence = model == nil ? nil : effort
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
    let model: AgentChatModel
    let sessionID: String
    let showAdvanced: () -> Void

    var body: some View {
        let options = model.selected.configOptions
        let summary = ModelSelectionSummary(options: options)
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

            if let effort = options.first(where: { $0.category == .thoughtLevel }) {
                let choices = effort.pickerChoices
                if (2...10).contains(choices.count) {
                    IntelligenceSteps(option: effort, choices: choices) { choice in
                        Task { await model.setConfigOption(effort.id, value: choice.id, sessionID: sessionID) }
                    }
                    .disabled(model.selected.configuring || model.selected.working)
                }
            }
            ModelControlStatus(model: model)
        }
        .frame(maxWidth: 340)
        .padding(.horizontal, 40)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background {
            Rectangle()
                .fill(.regularMaterial)
                .mask {
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.35)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .padding(.top, -22)
                .allowsHitTesting(false)
        }
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
    let model: AgentChatModel
    let sessionID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.selected.configOptions.filter { !$0.pickerChoices.isEmpty }) { option in
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
                ModelControlStatus(model: model)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Advanced")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(for: String.self) { optionID in
                ModelOptionChoices(model: model, sessionID: sessionID, optionID: optionID)
            }
        }
    }
}

private struct ModelOptionChoices: View {
    let model: AgentChatModel
    let sessionID: String
    let optionID: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        if let option = model.selected.configOptions.first(where: { $0.id == optionID }) {
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
            ModelControlStatus(model: model)
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
                await model.setConfigOption(option.id, value: choice.id, sessionID: sessionID)
                guard model.selectedID == sessionID,
                      model.selected.configOptions.contains(where: { $0.id == option.id && $0.currentValue == choice.id }) else { return }
                dismiss()
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
        .disabled(model.selected.configuring || model.selected.working)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("config-\(option.id)-\(choice.id)")
    }
}

private struct ModelControlStatus: View {
    let model: AgentChatModel

    var body: some View {
        if model.selected.configuring {
            ProgressView("Updating…").font(.footnote)
        } else if let error = model.selected.configError {
            Text(error).font(.footnote).foregroundStyle(ChatTheme.warning)
        } else if model.selected.working {
            Text("Changes are available after the reply finishes.")
                .font(.footnote)
                .foregroundStyle(ChatTheme.muted)
        }
    }
}

private extension SessionConfigOption {
    var pickerTitle: String { category == .thoughtLevel ? "Intelligence" : name }

    var pickerChoices: [Choice] {
        guard category == .thoughtLevel else { return choices }
        return choices.filter { !["none", "minimal"].contains($0.id.lowercased()) }
    }
}
