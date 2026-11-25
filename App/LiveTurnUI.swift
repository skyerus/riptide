import RiptideCore
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

extension View {
    func transcriptViewport(_ viewport: Binding<TranscriptViewport>, chat: WorkspaceChatID?,
                            showsJumpToLatest: Bool = true) -> some View {
        modifier(TranscriptViewportModifier(viewport: viewport, chat: chat, showsJumpToLatest: showsJumpToLatest))
    }

    func transcriptColumn() -> some View {
        padding(.horizontal, ChatTheme.gutter)
            .padding(.vertical, 14)
            .frame(maxWidth: ChatTheme.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
    }
}

struct TranscriptUserMessage: View {
    let text: String
    var receipt: MessageReceipt? = nil

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(ChatLinks.styled(AttributedString(text)))
                .textSelection(.enabled)
                .environment(\.openURL, ChatLinks.openURL)
                .foregroundStyle(ChatTheme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(ChatTheme.raised, in: RoundedRectangle(cornerRadius: 16))
            if let receipt {
                Text(receipt.rawValue)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(ChatTheme.muted)
                    .padding(.trailing, 6)
                    .accessibilityIdentifier("message-receipt")
            }
        }
        .padding(.leading, 32)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct ToolCallsMenuButton: View {
    @Binding var showsCompletedCalls: Bool

    var body: some View {
        Button(showsCompletedCalls ? "Hide Tool Calls" : "Show Tool Calls", systemImage: "terminal") {
            showsCompletedCalls.toggle()
        }
        .accessibilityIdentifier("toggle-completed-tool-calls")
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
    let showsJumpToLatest: Bool
    @Environment(WorkspaceState.self) private var workspace
    @State private var fingerDown = false
    @State private var latestOffset: CGFloat = 0

    func body(content: Content) -> some View {
        let initialAnchor: UnitPoint = chat.flatMap { workspace.readingOffset(for: $0) } == nil ? .bottom : .top
        content
            .defaultScrollAnchor(initialAnchor, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .alignment)
            .scrollPosition($viewport.position)
            .onChange(of: chat, initial: true) {
                viewport.restore(chat.flatMap { workspace.readingOffset(for: $0) })
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY <= 112
            } action: { _, atBottom in
                viewport.follow.geometryChanged(nearBottom: atBottom)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                Self.liveOffset(geometry)
            } action: { _, offset in
                latestOffset = offset
                if viewport.follow.canScrollAutomatically { viewport.position.scrollTo(y: offset) }
            }
            .onScrollPhaseChange { _, phase, context in
                let scrolling = phase == .interacting || phase == .decelerating
                let interaction: TranscriptFollow.Interaction = scrolling ? .scrolling : fingerDown ? .touching : .idle
                let previous = viewport.follow.interaction
                let geometry = context.geometry
                let nearBottom = geometry.contentSize.height - geometry.visibleRect.maxY <= 112
                viewport.follow.phaseChanged(interaction, nearBottom: nearBottom)
                if previous == .idle && interaction != .idle {
                    viewport.position = ScrollPosition()
                } else if previous == .scrolling && interaction != .scrolling {
                    if viewport.follow.canScrollAutomatically { viewport.position.scrollTo(y: Self.liveOffset(geometry)) }
                    if let chat {
                        workspace.rememberReadingOffset(viewport.follow.following ? nil : max(0, geometry.visibleRect.minY), for: chat)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(TranscriptContact { down in
                fingerDown = down
                guard viewport.follow.interaction != .scrolling else { return }
                viewport.follow.phaseChanged(down ? .touching : .idle, nearBottom: false)
                if down {
                    viewport.position = ScrollPosition()
                } else if viewport.follow.canScrollAutomatically {
                    viewport.position.scrollTo(y: latestOffset)
                }
            })
            .overlay(alignment: .bottomTrailing) {
                if showsJumpToLatest && !viewport.follow.following {
                    JumpToLatest {
                        if let chat { workspace.rememberReadingOffset(nil, for: chat) }
                        viewport.restore(nil)
                    }.padding(.trailing, ChatTheme.gutter).padding(.bottom, 6)
                }
            }
    }

    private nonisolated static func liveOffset(_ geometry: ScrollGeometry) -> CGFloat {
        max(0, geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.bottom)
    }
}

private struct TranscriptContact: UIGestureRecognizerRepresentable {
    let changed: (Bool) -> Void

    func makeUIGestureRecognizer(context: Context) -> ContactRecognizer {
        let recognizer = ContactRecognizer()
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesEnded = false
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: ContactRecognizer, context: Context) {
        switch recognizer.state {
        case .began: changed(true)
        case .ended, .cancelled, .failed: changed(false)
        default: break
        }
    }

    final class ContactRecognizer: UIGestureRecognizer {
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            if state == .possible { state = .began }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            if numberOfTouches <= touches.count { state = .ended }
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    }
}

struct TurnPulse: View {
    let title: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .footnote) private var dotSize = 5.0

    var body: some View {
        HStack(spacing: 9) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.25) / 1.25
                HStack(spacing: dotSize * 0.75) {
                    ForEach(0..<3) { index in
                        let phase = cycle - Double(index) * 0.16
                        let lift = reduceMotion ? 0 : max(0, sin(2 * .pi * phase))
                        Circle()
                            .fill(ChatTheme.sidebarAccent.opacity(0.58 + 0.42 * lift))
                            .frame(width: dotSize, height: dotSize)
                            .offset(y: -dotSize * 0.65 * lift)
                    }
                }
                .frame(height: dotSize * 2)
            }
            .accessibilityHidden(true)
            Text(title)
                .font(.footnote.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(ChatTheme.muted)
        .padding(.vertical, 3)
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
    let items: [CodexWorkItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                if item.detail.count > 220 || item.detail.split(separator: "\n").count > 4 {
                    DisclosureGroup {
                        detail(item).padding(.top, 4)
                    } label: {
                        heading(item)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        heading(item)
                        if !item.detail.isEmpty { detail(item) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .contentPanel()
        .accessibilityIdentifier("codex-activity")
    }

    private func heading(_ item: CodexWorkItem) -> some View {
        Label(item.title, systemImage: symbol(for: item))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(item.state == .failed ? ChatTheme.warning : ChatTheme.ink)
            .accessibilityValue(item.state.rawValue)
    }

    private func detail(_ item: CodexWorkItem) -> some View {
        Text(item.detail)
            .font(item.kind == .command ? .system(.caption, design: .monospaced) : .caption)
            .foregroundStyle(ChatTheme.muted)
            .textSelection(.enabled)
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
