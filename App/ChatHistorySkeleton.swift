import SwiftUI

struct ChatHistorySkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                placeholders
            } else {
                placeholders.phaseAnimator([true, false]) { content, bright in
                    content.opacity(bright ? 1 : 0.55)
                } animation: { _ in
                    .easeInOut(duration: 1.15)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading chat history")
        .accessibilityIdentifier("chat-history-skeleton")
    }

    private var placeholders: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width, 410)
            VStack(spacing: 25) {
                prompt(width: width * 0.59)
                reply(width: width, lines: [0.94, 0.86, 0.61])
                prompt(width: width * 0.40)
                reply(width: width, lines: [0.87, 0.96, 0.77, 0.50])
                prompt(width: width * 0.70)
                reply(width: width, lines: [0.93, 0.81, 0.65])
            }
            .padding(.top, 8)
            .mask {
                LinearGradient(stops: [
                    .init(color: .black, location: 0.45),
                    .init(color: .black.opacity(0.25), location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
        }
        .clipped()
        .transcriptColumn()
    }

    private func prompt(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(ChatTheme.raised)
            .frame(width: width, height: 40)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func reply(width: CGFloat, lines: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(lines, id: \.self) { line in
                Capsule()
                    .fill(ChatTheme.inset)
                    .frame(width: width * line, height: 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
