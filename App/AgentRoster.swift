import RiptideCore
import SwiftUI

private enum RosterLayout: String, CaseIterable, Identifiable {
    case grid = "Grid"
    case list = "List"

    var id: Self { self }
}

struct AgentRoster: View {
    let roster: [AgentChatModel]
    let localCodex: CodexLocalEndpoint?
    let remotes: RemoteStore
    @AppStorage("roster.layout") private var layout = RosterLayout.grid
    @AppStorage("roster.pinned") private var savedPins = Data()
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selectedTarget: AgentTarget?
    @State private var editing = false
    @State private var pairing = false
    @State private var forgetting: RemoteProfile?
    @State private var remoteError: String?

    private var pinnedIDs: [String] {
        let ids = (try? JSONDecoder().decode([String].self, from: savedPins))
            ?? Array(roster.prefix(4).map(\.target.id))
        return ids.filter { id in roster.contains { $0.target.id == id } }
    }

    private var pinned: [AgentChatModel] {
        pinnedIDs.compactMap { id in roster.first { $0.target.id == id } }
    }

    private var unpinned: [AgentChatModel] {
        roster.filter { !pinnedIDs.contains($0.target.id) }
            .sorted { $0.target.name.localizedStandardCompare($1.target.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agents")
                        .font(.title.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(remotes.profiles.isEmpty ? "Demo workspace" : "Your remotes")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(remotes.profiles) { remote in
                    NavigationLink {
                        PairedRemoteScreen(profile: remote, store: remotes)
                    } label: {
                        HStack {
                            Image(systemName: "server.rack").accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(remote.name).font(.headline)
                                Text(remote.kind.name).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            chevron
                        }
                        .padding(14)
                        .contentPanel()
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Forget remote", systemImage: "trash", role: .destructive) { forgetting = remote }
                    }
                    .accessibilityIdentifier("paired-\(remote.id.uuidString)")
                }
                if let remoteError { Text(remoteError).font(.footnote).foregroundStyle(.secondary) }
                if let localCodex {
                    NavigationLink {
                        CodexLiveScreen(endpoint: localCodex)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer")
                                .font(.body.weight(.medium))
                                .frame(width: 36, height: 36)
                                .background(ChatTheme.inset, in: RoundedRectangle(cornerRadius: 10))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Codex on this Mac").font(.headline)
                                Text("Live chat and voice").font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            chevron
                        }
                        .padding(14)
                        .background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("local-codex")
                }
                if layout == .grid, !pinned.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                               count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                        ForEach(pinned, id: \.target.id) { agent in agentButton(agent, tile: true) }
                    }
                }
                let rowAgents = layout == .list ? pinned + unpinned : unpinned
                if !rowAgents.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        if layout == .grid, !pinned.isEmpty {
                            Text("Other agents")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 8)
                        }
                        ForEach(rowAgents, id: \.target.id) { agent in agentButton(agent, tile: false) }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(ChatTheme.background.ignoresSafeArea())
        .navigationTitle("Riptide")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Pair remote", systemImage: "plus") { pairing = true }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("pair-remote")
                Button("Edit") { editing = true }
                    .accessibilityIdentifier("edit-roster")
            }
        }
        .sheet(isPresented: $pairing) { PairRemoteScreen(store: remotes) }
        .confirmationDialog("Forget this remote?", isPresented: Binding(
            get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }
        ), titleVisibility: .visible, presenting: forgetting) { remote in
            Button("Forget", role: .destructive) {
                do { try remotes.forget(remote); remoteError = nil }
                catch { remoteError = error.localizedDescription }
                forgetting = nil
            }
        } message: { _ in
            Text("Riptide removes the connection and its token from this device. Chats on the host stay in place.")
        }
        .sheet(isPresented: $editing) {
            RosterEditor(
                roster: roster.map(\.target),
                pins: Binding(
                    get: { pinnedIDs },
                    set: { if let data = try? JSONEncoder().encode($0) { savedPins = data } }
                ),
                layout: $layout
            )
        }
        .navigationDestination(item: $selectedTarget) { target in
            if let model = roster.first(where: { $0.target == target }) {
                ChatScreen(model: model)
            }
        }
    }

    private func agentButton(_ agent: AgentChatModel, tile: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18)
        return Button {
            agent.selectMain()
            selectedTarget = agent.target
        } label: {
            if tile {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        symbol(agent.target)
                        Spacer(minLength: 4)
                        chevron
                    }
                    agentName(agent)
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
                .background(ChatTheme.surface, in: shape)
                .overlay { shape.strokeBorder(ChatTheme.border, lineWidth: 0.5) }
                .contentShape(shape)
            } else {
                HStack(spacing: 12) {
                    symbol(agent.target)
                    agentName(agent)
                    Spacer(minLength: 4)
                    chevron
                }
                .padding(.vertical, 8)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(agent.target.name)
        .accessibilityValue(agent.mainActivity ?? "")
        .accessibilityHint("Opens Main Chat")
        .accessibilityIdentifier("agent-\(agent.target.id)")
    }

    private func agentName(_ agent: AgentChatModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(agent.target.name)
                .font(.headline)
                .multilineTextAlignment(.leading)
            if let activity = agent.mainActivity {
                Text(activity)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ChatTheme.accent)
            }
        }
    }

    private func symbol(_ target: AgentTarget) -> some View {
        let name = switch target.id {
        case "openclaw": "terminal"
        case "hermes": "sparkle"
        default: "bubble.left"
        }
        return Image(systemName: name)
            .font(.system(size: 15, weight: .medium))
            .frame(width: 34, height: 34)
            .background(ChatTheme.inset, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

private struct RosterEditor: View {
    let roster: [AgentTarget]
    @Binding var pins: [String]
    @Binding var layout: RosterLayout
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Layout") {
                    Picker("Layout", selection: $layout) {
                        ForEach(RosterLayout.allCases) { mode in Text(mode.rawValue).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("roster-layout")
                }
                Section {
                    ForEach(pins, id: \.self) { id in
                        if let agent = roster.first(where: { $0.id == id }) {
                            pinRow(agent, pinned: true)
                        }
                    }
                    .onMove { pins.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Pinned")
                } footer: {
                    Text("Pin up to four agents and drag to set their order.")
                }
                let others = roster.filter { !pins.contains($0.id) }
                if !others.isEmpty {
                    Section("Other agents") {
                        ForEach(others) { agent in pinRow(agent, pinned: false) }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit agents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func pinRow(_ agent: AgentTarget, pinned: Bool) -> some View {
        HStack {
            Text(agent.name)
            Spacer()
            Button {
                if pinned { pins.removeAll { $0 == agent.id } }
                else if pins.count < 4 { pins.append(agent.id) }
            } label: {
                Image(systemName: pinned ? "pin.slash" : "pin")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .disabled(!pinned && pins.count >= 4)
            .accessibilityLabel(pinned ? "Unpin \(agent.name)" : "Pin \(agent.name)")
            .accessibilityIdentifier("\(pinned ? "unpin" : "pin")-\(agent.id)")
        }
    }
}
