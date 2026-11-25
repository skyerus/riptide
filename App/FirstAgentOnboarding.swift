import RiptideCore
import SwiftUI

struct FirstAgentOnboarding: View {
    let remotes: RemoteStore
    @State private var selection: Connector?

    private struct Connector: Identifiable {
        let kind: RemoteKind
        let symbol: String
        let connection: String
        var id: RemoteKind { kind }

        static let options: [Connector] = [
            .init(kind: .hermes, symbol: "waveform", connection: "SSH or private ACP endpoint"),
            .init(kind: .openClaw, symbol: "terminal", connection: "SSH or private ACP endpoint"),
            .init(kind: .codex, symbol: "desktopcomputer", connection: "Private Codex App Server")
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "link")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(ChatTheme.sidebarAccent)
                        .frame(width: 48, height: 48)
                        .background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityHidden(true)
                        .padding(.bottom, 10)
                    Text("Connect your first agent")
                        .font(.largeTitle.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Choose an agent you already run. Once it’s connected, its chats and Inbox will be here.")
                        .font(.body)
                        .foregroundStyle(ChatTheme.muted)
                }
                VStack(spacing: 4) {
                    ForEach(Connector.options) { connector in connectorRow(connector) }
                }
                Link(destination: URL(string: "https://github.com/skyerus/riptide#pair-private-remotes")!) {
                    Label("Host setup guide", systemImage: "arrow.up.right")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(ChatTheme.muted)
                        .frame(minHeight: 44)
                }
            }
            .foregroundStyle(ChatTheme.ink)
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.horizontal, ChatTheme.gutter + 4)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
        .background(ChatTheme.background.ignoresSafeArea())
        .sheet(item: $selection) { connector in
            PairRemoteScreen(store: remotes, initialKind: connector.kind)
        }
    }

    private func connectorRow(_ connector: Connector) -> some View {
        Button {
            selection = connector
        } label: {
            HStack(spacing: 14) {
                Image(systemName: connector.symbol)
                    .font(.title3)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(connector.kind.name).font(.headline)
                    Text(connector.connection)
                        .font(.footnote)
                        .foregroundStyle(ChatTheme.muted)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ChatTheme.muted)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 42)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(connector.kind.name)
        .accessibilityHint(connector.connection)
        .accessibilityIdentifier("connect-\(connector.kind.rawValue)")
    }
}
