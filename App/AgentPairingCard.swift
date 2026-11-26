import RiptideCore
import SwiftUI

struct AgentPairingCard: View {
    let name: String
    let connecting: Bool
    let isDisabled: Bool
    let error: String?
    let connect: () -> Void
    let skip: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ChatTheme.attention)
                    .frame(width: 42, height: 42)
                    .background(ChatTheme.attention.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.headline)
                        .foregroundStyle(ChatTheme.ink)
                    Text("Add to Agents")
                        .font(.subheadline)
                        .foregroundStyle(ChatTheme.muted)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("agent-pairing-title")
            }

            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(ChatTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("agent-pairing-error")
            }

            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 4))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                skipButton
                connectButton
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-pairing-card")
        .disabled(isDisabled)
    }

    private var skipButton: some View {
        Button("Skip", role: .cancel, action: skip)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(ChatTheme.muted)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .accessibilityIdentifier("skip-agent-pairing")
    }

    private var connectButton: some View {
        Button(action: connect) {
            ZStack {
                Text("Connecting…")
                    .padding(.leading, 27)
                    .hidden()
                    .accessibilityHidden(true)

                HStack(spacing: 7) {
                    if connecting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(ChatTheme.ink)
                            .accessibilityHidden(true)
                    }
                    Text(connecting ? "Connecting…" : error == nil ? "Connect agent" : "Try again")
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isDisabled ? ChatTheme.ink : ChatTheme.background)
            .frame(minHeight: 31)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(ChatTheme.sidebarAccent)
        .accessibilityIdentifier("connect-hermes-agent")
    }
}

struct AgentPairingReceipt: View {
    let name: String
    let connected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: connected ? "checkmark.circle.fill" : "minus.circle")
                .font(.body)
                .foregroundStyle(connected ? ChatTheme.sidebarAccent : ChatTheme.muted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ChatTheme.ink)
                Text(connected ? "Connected" : "Skipped")
                    .font(.caption)
                    .foregroundStyle(ChatTheme.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(connected ? "connected-agent-receipt" : "skipped-agent-receipt")
    }
}

#if DEBUG
enum AgentPairingFixture {
    static var isEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["RIPTIDE_PAIRING_FIXTURE"] == "1" && environment["RIPTIDE_FIXTURE_NAMESPACE"] != nil
    }

    static func connect(_ invitation: HermesPairingInvitation, retrying: Bool) async throws -> String {
        try await Task.sleep(for: .seconds(3))
        if !retrying { throw Unavailable() }
        return invitation.displayName
    }

    private struct Unavailable: LocalizedError {
        var errorDescription: String? { "Couldn’t reach this agent." }
    }
}
#endif
