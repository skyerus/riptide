import RiptideCore
import SwiftUI

extension View {
    func transcriptViewport(_ viewport: Binding<TranscriptViewport>, chat: WorkspaceChatID?) -> some View {
        modifier(TranscriptViewportModifier(viewport: viewport, chat: chat))
    }
}

struct TranscriptViewport {
    var follow = TranscriptFollow()
    var position = ScrollPosition()

    mutating func restore(_ offset: CGFloat?) {
        follow = TranscriptFollow(following: offset == nil)
        position = offset.map { ScrollPosition(y: $0) } ?? ScrollPosition(edge: .bottom)
    }
}

private struct TranscriptViewportModifier: ViewModifier {
    @Binding var viewport: TranscriptViewport
    let chat: WorkspaceChatID?
    @Environment(WorkspaceState.self) private var workspace

    func body(content: Content) -> some View {
        content
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .scrollPosition($viewport.position)
            .onChange(of: chat, initial: true) {
                viewport.restore(chat.flatMap { workspace.readingOffset(for: $0) })
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY <= 112
            } action: { _, atBottom in
                viewport.follow.geometryChanged(nearBottom: atBottom)
            }
            .onScrollPhaseChange { _, phase, context in
                let userGesture = phase == .tracking || phase == .interacting || phase == .decelerating
                let settled = viewport.follow.interacting && !userGesture
                let geometry = context.geometry
                let nearBottom = geometry.contentSize.height - geometry.visibleRect.maxY <= 112
                viewport.follow.phaseChanged(userGesture: userGesture, nearBottom: nearBottom)
                if settled, let chat {
                    workspace.rememberReadingOffset(nearBottom ? nil : max(0, geometry.visibleRect.minY), for: chat)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !viewport.follow.following {
                    JumpToLatest {
                        if let chat { workspace.rememberReadingOffset(nil, for: chat) }
                        viewport.restore(nil)
                    }.padding(12)
                }
            }
    }
}

struct TurnPulse: View {
    let title: String
    var waitingForUser = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 9) {
            if waitingForUser || reduceMotion {
                Image(systemName: waitingForUser ? "hand.raised" : "waveform")
                    .accessibilityHidden(true)
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .tint(ChatTheme.accent)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.footnote.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(waitingForUser ? ChatTheme.warning : ChatTheme.accent)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(waitingForUser ? ChatTheme.warning.opacity(0.09) : ChatTheme.selected.opacity(0.65), in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("turn-progress")
    }
}

struct JumpToLatest: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("Latest", systemImage: "arrow.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ChatTheme.ink)
                .padding(.horizontal, 13)
                .frame(minHeight: 44)
                .background(ChatTheme.raised, in: Capsule())
                .overlay { Capsule().strokeBorder(ChatTheme.border).allowsHitTesting(false) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Jump to latest message")
        .accessibilityIdentifier("jump-to-latest")
    }
}

struct TurnPlanCard: View {
    let steps: [TurnPlanStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Plan", systemImage: "list.bullet.rectangle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ChatTheme.ink)
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                Label(step.text, systemImage: step.state == .completed ? "checkmark.circle.fill"
                      : step.state == .inProgress ? "circle.lefthalf.filled" : "circle")
                    .font(.footnote)
                    .foregroundStyle(step.state == .inProgress ? ChatTheme.accent : ChatTheme.muted)
                    .accessibilityValue(step.state == .completed ? "Complete" : step.state == .inProgress ? "In progress" : "Pending")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentPanel()
    }
}

struct CodexActivityCard: View {
    let progress: CodexTurnProgress
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !progress.plan.isEmpty { TurnPlanCard(steps: progress.plan) }
            if !progress.items.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(progress.items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(item.title, systemImage: symbol(for: item))
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(item.state == .failed ? ChatTheme.warning : ChatTheme.ink)
                                    .accessibilityValue(item.state.rawValue)
                                if !item.detail.isEmpty {
                                    Text(item.detail)
                                        .font(item.kind == .command ? .system(.caption, design: .monospaced) : .caption)
                                        .foregroundStyle(ChatTheme.muted)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                } label: {
                    Label("Activity · \(progress.items.count)", systemImage: "waveform.path")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(ChatTheme.ink)
                }
                .padding(12)
                .contentPanel()
                .accessibilityIdentifier("codex-activity")
            }
        }
    }

    private func symbol(for item: CodexWorkItem) -> String {
        switch item.state {
        case .finished: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .running:
            switch item.kind {
            case .command: "terminal"
            case .changes: "doc.badge.plus"
            case .tool: "wrench"
            case .search: "magnifyingglass"
            case .planning: "list.bullet"
            case .summary: "text.alignleft"
            }
        }
    }
}
