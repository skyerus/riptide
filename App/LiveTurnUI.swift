import RiptideCore
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

extension View {
    func transcriptViewport(_ viewport: Binding<TranscriptViewport>, chat: WorkspaceChatID? = nil,
                            composerFocused: Bool, shortContentAlignment: UnitPoint = .top,
                            showsJumpToLatest: Bool = true) -> some View {
        modifier(TranscriptViewportModifier(viewport: viewport, chat: chat, composerFocused: composerFocused,
                                            shortContentAlignment: shortContentAlignment,
                                            showsJumpToLatest: showsJumpToLatest))
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
    var photos: [TranscriptPhoto] = []
    var receipt: MessageReceipt? = nil
    var photoClient: CodexLiveClient? = nil

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            TranscriptPhotoStrip(photos: photos, photoClient: photoClient)
            if !text.isEmpty {
                Text(ChatLinks.styled(AttributedString(text)))
                    .textSelection(.enabled)
                    .environment(\.openURL, ChatLinks.openURL)
                    .foregroundStyle(ChatTheme.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(ChatTheme.raised, in: RoundedRectangle(cornerRadius: 16))
            }
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

struct ContextCompactionLine: View {
    let compaction: ContextCompaction

    var body: some View {
        switch compaction.state {
        case .running(let since):
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                line("Compacting context", elapsed: timeline.date.timeIntervalSince(since), running: true)
            }
        case .completed(let elapsed):
            line("Context compacted", elapsed: elapsed, running: false)
        }
    }

    private func line(_ title: String, elapsed: TimeInterval?, running: Bool) -> some View {
        let duration = elapsed.map {
            Duration.seconds(max(0, $0.rounded(.down))).formatted(
                .units(allowed: [.hours, .minutes, .seconds], width: .narrow, fractionalPart: .hide)
            )
        }
        return HStack(spacing: 8) {
            if running {
                ProgressView().controlSize(.mini).accessibilityHidden(true)
            } else {
                Image(systemName: "arrow.down.right.and.arrow.up.left").accessibilityHidden(true)
            }
            Text(duration.map { "\(title) · \($0)" } ?? title)
                .monospacedDigit()
                .accessibilityIdentifier(running ? "context-compaction-running" : "context-compaction-completed")
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(ChatTheme.muted)
    }
}

extension BidirectionalCollection where Element == CodexTranscriptTurn {
    func latestUserMessageLocation(activeTurnID: String?) -> (turnID: String, messageID: String)? {
        for turn in reversed() {
            let messages = turn.visibleMessages(isActive: turn.id == activeTurnID)
            if let message = messages.last(where: { $0.role == .user }) {
                return (turn.id, message.id)
            }
        }
        return nil
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
    private(set) var jumpRequest = 0

    mutating func jumpToLatest() {
        follow.jumpToLatest()
        jumpRequest += 1
    }
}

private struct TranscriptViewportModifier: ViewModifier {
    @Binding var viewport: TranscriptViewport
    let chat: WorkspaceChatID?
    let composerFocused: Bool
    let shortContentAlignment: UnitPoint
    let showsJumpToLatest: Bool
    @State private var fingerDown = false
    @State private var position = ScrollPosition()

    func body(content: Content) -> some View {
        content
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(shortContentAlignment, for: .alignment)
            .scrollPosition($position)
            .onChange(of: chat, initial: true) {
                viewport.jumpToLatest()
            }
            .onChange(of: composerFocused) { _, focused in
                if focused { viewport.jumpToLatest() }
            }
            .onChange(of: viewport.jumpRequest) { scrollToLatest() }
            .background {
                TranscriptAppearanceObserver {
                    if viewport.follow.canScrollAutomatically { scrollToLatest() }
                }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
            .onScrollGeometryChange(for: Bool.self, of: Self.isAtLatest) { _, atBottom in
                viewport.follow.geometryChanged(nearBottom: atBottom)
            }
            .onScrollGeometryChange(for: CGFloat.self, of: Self.liveOffset) { _, _ in
                if viewport.follow.canScrollAutomatically { scrollToLatest() }
            }
            .onScrollPhaseChange { _, phase, context in
                let scrolling = phase == .interacting || phase == .decelerating
                let interaction: TranscriptFollow.Interaction = scrolling ? .scrolling : fingerDown ? .touching : .idle
                let previous = viewport.follow.interaction
                let geometry = context.geometry
                viewport.follow.phaseChanged(interaction, nearBottom: Self.isAtLatest(geometry))
                if previous == .scrolling && viewport.follow.canScrollAutomatically { scrollToLatest() }
            }
            .contentShape(Rectangle())
            .gesture(TranscriptContact { down in
                fingerDown = down
                guard viewport.follow.interaction != .scrolling else { return }
                viewport.follow.phaseChanged(down ? .touching : .idle, nearBottom: false)
                if down {
                    position = ScrollPosition()
                } else if viewport.follow.canScrollAutomatically {
                    scrollToLatest()
                }
            })
            .overlay(alignment: .bottomTrailing) {
                if showsJumpToLatest && !viewport.follow.following {
                    JumpToLatest { viewport.jumpToLatest() }
                        .padding(.trailing, ChatTheme.gutter).padding(.bottom, 6)
                }
            }
    }

    private func scrollToLatest() {
        // The edge follows the transcript's layout when sending changes both the composer and the content.
        position.scrollTo(edge: .bottom)
    }

    private nonisolated static func isAtLatest(_ geometry: ScrollGeometry) -> Bool {
        let offset = max(0, geometry.contentOffset.y + geometry.contentInsets.top)
        // Allow rounding at the bottom while preserving even a short scroll into history.
        return offset >= liveOffset(geometry) - 1
    }

    private nonisolated static func liveOffset(_ geometry: ScrollGeometry) -> CGFloat {
        // The container already excludes the space reserved by the scroll insets.
        max(0, geometry.contentSize.height - geometry.containerSize.height)
    }
}

private struct TranscriptAppearanceObserver: UIViewControllerRepresentable {
    // Navigation can reset the scroll view after SwiftUI's onAppear on iOS 26.
    let didAppear: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.didAppear = didAppear
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.didAppear = didAppear
    }

    final class Controller: UIViewController {
        var didAppear: (() -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            didAppear?()
        }
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

struct LiveTurnActivity<Details: View>: View {
    let currentTool: String?
    let hasActivity: Bool
    @ViewBuilder let details: () -> Details
    @State private var expanded = false

    var body: some View {
        let title = currentTool ?? "Thinking"
        VStack(alignment: .leading, spacing: 4) {
            Text("Working")
                .font(.caption.weight(.medium))
                .foregroundStyle(ChatTheme.muted)
                .accessibilityIdentifier("turn-working")
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    ActivityShimmer(title: title)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .font(.subheadline)
                .foregroundStyle(ChatTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Hides turn activity" : "Shows turn activity")
            .accessibilityIdentifier("live-turn-activity")
            if expanded {
                if hasActivity {
                    details()
                        .padding(.leading, 12)
                } else {
                    Text("No tool calls yet")
                        .font(.caption)
                        .foregroundStyle(ChatTheme.muted)
                        .padding(.leading, 12)
                }
            }
        }
    }
}

private struct ActivityShimmer: View {
    let title: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var began = Date.now

    var body: some View {
        Text(title)
            .lineLimit(1)
            .overlay {
                if !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let elapsed = max(0, context.date.timeIntervalSince(began) - 0.6)
                        let sweep = min(1, elapsed.truncatingRemainder(dividingBy: 4))
                        let center = -0.3 + 1.6 * sweep
                        LinearGradient(
                            colors: [.clear, ChatTheme.ink, .clear],
                            startPoint: UnitPoint(x: center - 0.22, y: 0.5),
                            endPoint: UnitPoint(x: center + 0.22, y: 0.5)
                        )
                    }
                    .mask { Text(title).lineLimit(1) }
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                }
            }
            .onChange(of: title) { began = .now }
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

struct CodexActivityList: View {
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
