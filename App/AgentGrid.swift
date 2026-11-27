import SwiftUI

struct AgentGrid: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title2) private var avatarSize = 76.0
    @State private var editingPhoto: WorkspaceAgent?

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
              count: typeSize.isAccessibilitySize ? 2 : 3)
    }

    var body: some View {
        let agents = workspace.rosterAgents()
        let urgent = Set(workspace.approvalIDs.map(\.chat.workspace))
        ScrollView {
            LazyVGrid(columns: columns, alignment: .center, spacing: 24) {
                ForEach(agents) { agent in
                    item(agent, needsAttention: urgent.contains(agent.id))
                }
            }
            .padding(.horizontal, ChatTheme.gutter)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .accessibilityIdentifier("agent-grid")
        .sheet(item: $editingPhoto) { agent in
            AgentAvatarEditor(agent: agent).environment(workspace)
        }
    }

    private func item(_ agent: WorkspaceAgent, needsAttention: Bool) -> some View {
        Button {
            workspace.openMainChat(agent.id)
        } label: {
            VStack(spacing: 9) {
                AgentAvatar(agent: agent, size: min(avatarSize, 90))
                    .overlay(alignment: .bottomTrailing) {
                        if needsAttention {
                            Circle().fill(ChatTheme.attention)
                                .frame(width: 11, height: 11)
                                .padding(2)
                                .background(ChatTheme.background, in: Circle())
                                .offset(x: -2, y: -2)
                                .accessibilityHidden(true)
                        }
                    }
                Text(agent.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ChatTheme.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(agent.name)
        .accessibilityValue(needsAttention ? "Needs attention" : "")
        .accessibilityHint("Opens Main Chat")
        .accessibilityIdentifier("sidebar-agent-\(agent.id)")
        .contextMenu {
            Button("Edit profile photo", systemImage: "person.crop.circle") {
                editingPhoto = agent
            }
            .accessibilityIdentifier("edit-agent-photo")
        }
    }
}
