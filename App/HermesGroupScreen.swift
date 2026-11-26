import RiptideCore
import SwiftUI

struct HermesGroupCatalog: View {
    let sources: [WorkspaceAgent]
    @Binding var creating: Bool
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshots: [String: Snapshot] = [:]
    @State private var loading = false

    private struct Snapshot: Sendable {
        let rooms: [HermesGroup]
        var failure: String?
        var unsupported = false
    }

    private struct RoomIdentity: Hashable {
        let authority: String
        let room: String
    }

    private struct RoomLink: Identifiable {
        let id: RoomIdentity
        let room: HermesGroup
        let source: WorkspaceAgent
    }

    private var availableSources: [WorkspaceAgent] {
        sources.filter { snapshots[$0.id]?.unsupported != true }
    }

    private var rooms: [RoomLink] {
        var seen = Set<RoomIdentity>()
        // Prefer a reachable connection if two pairings list the same room.
        let ordered = sources.filter { snapshots[$0.id]?.failure == nil } + sources.filter { snapshots[$0.id]?.failure != nil }
        return ordered.flatMap { source in
            (snapshots[source.id]?.rooms ?? []).compactMap { room in
                let id = RoomIdentity(authority: room.authorityGatewayId ?? source.id, room: room.id)
                guard seen.insert(id).inserted else { return nil }
                return RoomLink(id: id, room: room, source: source)
            }
        }
    }

    var body: some View {
        let rooms = rooms
        List {
            ForEach(rooms) { link in
                Button {
                    workspace.openHermesGroup(link.room.id, in: link.source.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        WorkspaceRow(title: link.room.name,
                                     subtitle: link.room.members.map(\.label).joined(separator: ", "),
                                     symbol: "person.2")
                        Text(link.source.name)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(ChatTheme.muted)
                            .padding(.leading, WorkspaceRow.textInset)
                    }
                    .accessibilityElement(children: .combine)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("hermes-group-row-\(link.room.id)")
                .sidebarRowStyle(divider: link.id != rooms.last?.id)
            }
            ForEach(sources) { source in
                if let failure = snapshots[source.id]?.failure {
                    Text("\(source.name) · \(failure)")
                        .foregroundStyle(ChatTheme.muted).font(.footnote).sidebarRowStyle()
                }
            }
            if rooms.isEmpty {
                if sources.contains(where: { snapshots[$0.id] == nil }) {
                    ProgressView("Loading group chats…").sidebarRowStyle()
                } else if availableSources.isEmpty {
                    ContentUnavailableView("Group chats unavailable", systemImage: "person.2",
                                           description: Text("Enable group chat access on a paired Hermes connection."))
                        .sidebarRowStyle()
                } else if availableSources.contains(where: { snapshots[$0.id]?.failure == nil }) {
                    ContentUnavailableView("No group chats yet", systemImage: "person.2",
                                           description: Text("Tap + to start a conversation with your bots."))
                        .sidebarRowStyle()
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(ChatTheme.background)
        .refreshable { await reload() }
        .sheet(isPresented: $creating) {
            HermesGroupCreate(sources: availableSources.isEmpty ? sources : availableSources) { room, source in
                creating = false
                workspace.openHermesGroup(room.id, in: source.id)
            }
            .environment(workspace)
        }
        .task(id: scenePhase == .active && workspace.path.isEmpty ? sources.map(\.id) : nil) {
            guard scenePhase == .active, workspace.path.isEmpty else { return }
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        await withTaskGroup(of: (String, Snapshot).self) { requests in
            for source in sources {
                let id = source.id
                let client = workspace.hermesGroupsClient(for: id)
                let cached = snapshots[id]?.rooms ?? []
                requests.addTask {
                    guard let client else { return (id, Snapshot(rooms: cached, failure: "Unlock this device or pair Hermes again.")) }
                    do {
                        return (id, Snapshot(rooms: try await client.groups()))
                    } catch HermesGroupError.unsupported {
                        return (id, Snapshot(rooms: [], unsupported: true))
                    } catch {
                        return (id, Snapshot(rooms: cached, failure: error.localizedDescription))
                    }
                }
            }
            for await (id, snapshot) in requests {
                if !Task.isCancelled { snapshots[id] = snapshot }
            }
        }
    }
}

struct HermesGroupCreate: View {
    let sources: [WorkspaceAgent]
    let created: (HermesGroup, WorkspaceAgent) -> Void
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var sourceID: String?
    @FocusState private var editingName: Bool
    @State private var name = ""
    @State private var bots: [HermesGroupBot] = []
    @State private var loadedSourceID: String?
    @State private var selection = Set<String>()
    @State private var loading = false
    @State private var creating = false
    @State private var failure: String?
    @State private var roomID = UUID().uuidString.lowercased()

    init(sources: [WorkspaceAgent], created: @escaping (HermesGroup, WorkspaceAgent) -> Void) {
        self.sources = sources
        self.created = created
        _sourceID = State(initialValue: sources.count == 1 ? sources.first?.id : nil)
    }

    private var source: WorkspaceAgent? { sources.first { $0.id == sourceID } }
    private var title: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var ready: Bool {
        sourceID != nil && loadedSourceID == sourceID && !title.isEmpty &&
        title.unicodeScalars.count <= 200 && (2...6).contains(selection.count)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Hermes connection", selection: $sourceID) {
                        if sourceID == nil { Text("Choose").tag(nil as String?) }
                        ForEach(sources) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("hermes-group-host")
                } footer: {
                    if let source {
                        Text("Runs on \(source.name), even when Riptide is closed.")
                    } else {
                        Text("Choose the connection that serves your bots.")
                    }
                }
                Section {
                    TextField("Group name", text: $name)
                        .textInputAutocapitalization(.words)
                        .focused($editingName)
                        .submitLabel(.done)
                        .onSubmit { editingName = false }
                        .accessibilityIdentifier("hermes-group-name")
                        .onChange(of: name) { resetIntent() }
                }
                if source != nil { botSection }
                if let failure {
                    Section {
                        Text(failure).foregroundStyle(ChatTheme.warning).font(.footnote)
                        if bots.isEmpty {
                            Button("Reload bots") { Task { await loadBots() } }
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .background(ChatTheme.background)
            .navigationTitle("New group chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(creating) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(creating ? "Creating…" : "Create") { Task { await create() } }
                        .disabled(!ready || creating || loading)
                        .accessibilityIdentifier("create-hermes-group")
                }
            }
            .interactiveDismissDisabled(creating)
            .disabled(creating)
            .onChange(of: sourceID) {
                bots = []
                loadedSourceID = nil
                selection = []
                resetIntent()
            }
            .task(id: sourceID) { await loadBots() }
        }
    }

    private var botSection: some View {
        Section("Choose 2–6 bots") {
            if loading { ProgressView("Loading bots…") }
            ForEach(bots) { bot in
                Button {
                    if !selection.insert(bot.id).inserted { selection.remove(bot.id) }
                    editingName = false
                    resetIntent()
                } label: {
                    HStack(spacing: 12) {
                        GroupIdentityIcon(name: bot.label, size: 33)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bot.label).font(.subheadline.weight(.semibold)).foregroundStyle(ChatTheme.ink)
                            Text("@\(bot.handle)").font(.caption).foregroundStyle(ChatTheme.muted)
                        }
                        Spacer()
                        Image(systemName: selection.contains(bot.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selection.contains(bot.id) ? ChatTheme.sidebarAccent : ChatTheme.muted)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(selection.count == 6 && !selection.contains(bot.id))
                .accessibilityAddTraits(selection.contains(bot.id) ? [.isSelected] : [])
                .accessibilityIdentifier("hermes-group-bot-\(bot.id)")
            }
            if !loading && bots.count < 2 && failure == nil {
                Text("This gateway needs at least two available bot profiles.")
                    .foregroundStyle(ChatTheme.muted)
            }
        }
    }

    private func resetIntent() {
        roomID = UUID().uuidString.lowercased()
        failure = nil
    }

    private func loadBots() async {
        guard let source else { return }
        let id = source.id
        guard let client = workspace.hermesGroupsClient(for: id) else {
            failure = "Unlock this device or pair Hermes again."
            return
        }
        loading = true
        failure = nil
        defer { if sourceID == id { loading = false } }
        do {
            let capabilities = try await client.capabilities()
            try Task.checkCancellation()
            guard sourceID == id else { return }
            guard capabilities.driver, capabilities.offers("create") else {
                failure = "Start or update the Hermes gateway to create group chats."
                return
            }
            let roster = try await client.bots(capabilities: capabilities)
            try Task.checkCancellation()
            if sourceID == id {
                bots = roster
                loadedSourceID = id
            }
        } catch {
            if sourceID == id && !Task.isCancelled { failure = error.localizedDescription }
        }
    }

    private func create() async {
        guard ready, !creating, let source, let client = workspace.hermesGroupsClient(for: source.id) else { return }
        creating = true
        failure = nil
        defer { creating = false }
        do {
            let members = bots.filter { selection.contains($0.id) }
            let room = try await client.create(id: roomID, name: title, bots: members)
            created(room, source)
        } catch { failure = error.localizedDescription }
    }
}

struct HermesGroupScreen: View {
    let workspaceName: String
    let session: HermesGroupSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var composing: Bool
    @State private var showingMembers = false
    @State private var renaming = false
    @State private var disbanding = false
    @State private var name = ""

    var body: some View {
        VStack(spacing: 0) {
            if let error = session.readError {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(error).font(.footnote)
                    Spacer(minLength: 0)
                    Button("Refresh") { Task { await session.refresh() } }.font(.footnote.weight(.semibold))
                }
                .foregroundStyle(ChatTheme.warning)
                .padding(.horizontal, ChatTheme.gutter)
                .padding(.vertical, 8)
            }
            transcript
            composer
        }
        .frame(maxWidth: ChatTheme.readingWidth)
        .frame(maxWidth: .infinity)
        .background(ChatTheme.background.ignoresSafeArea())
        .navigationTitle(session.snapshot?.room.name ?? "Group chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { showingMembers = true } label: {
                    VStack(spacing: 2) {
                        Text(session.snapshot?.room.name ?? "Group chat")
                            .font(.headline).foregroundStyle(ChatTheme.ink).lineLimit(1)
                        Label(roomByline, systemImage: "person.2")
                            .labelStyle(.titleAndIcon)
                            .font(.caption).foregroundStyle(ChatTheme.muted).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(session.members.isEmpty)
                .accessibilityIdentifier("hermes-group-heading")
                .accessibilityLabel(session.snapshot?.room.name ?? "Group chat")
                .accessibilityValue(roomByline)
                .accessibilityHint("Show group members")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if session.offers("stop"), session.driver?.working == true || pausedDiscussion != nil {
                        Button("Stop discussion", systemImage: "stop.circle", role: .destructive) {
                            Task { await session.stop() }
                        }
                    }
                    Button("Members", systemImage: "person.2") { showingMembers = true }
                    if session.offers("rename") {
                        Button("Rename group", systemImage: "pencil") {
                            name = session.snapshot?.room.name ?? ""
                            renaming = true
                        }
                    }
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await session.refresh() } }
                    if session.offers("disband") {
                        Button("Disband group", systemImage: "trash", role: .destructive) { disbanding = true }
                    }
                } label: {
                    Label("Group chat actions", systemImage: "ellipsis.circle")
                }
                .disabled(session.snapshot == nil || session.acting || session.sending)
                .accessibilityIdentifier("hermes-group-actions")
            }
        }
        .sheet(isPresented: $showingMembers) { memberList }
        .alert("Rename group", isPresented: $renaming) {
            TextField("Group name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                Task { await session.rename(title) }
            }
        }
        .confirmationDialog("Disband this group?", isPresented: $disbanding, titleVisibility: .visible) {
            Button("Disband group", role: .destructive) {
                Task { if await session.disband() { dismiss() } }
            }
        } message: {
            Text("This removes the shared conversation from Hermes.")
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await session.refresh()
                try? await Task.sleep(for: .seconds(session.readError == nil ? 2 : 5))
            }
        }
    }

    private var roomByline: String {
        if session.members.isEmpty { return workspaceName }
        return "\(session.members.count) bots · \(workspaceName)"
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if session.snapshot == nil && session.readError == nil {
                    ProgressView("Opening group…").frame(maxWidth: .infinity)
                } else if session.snapshot != nil && !session.events.contains(where: \.isMessage) {
                    ContentUnavailableView("Start the conversation", systemImage: "person.2",
                        description: Text("Message everyone or use @ to address a bot."))
                }
                ForEach(session.events) { event in
                    if event.isMessage, let text = event.text, !text.isEmpty { message(event, text: text) }
                    else if let notice = notice(for: event) {
                        Label(notice, systemImage: "info.circle")
                            .font(.caption).foregroundStyle(ChatTheme.muted)
                    }
                }
                statusCards
            }
            .padding(.horizontal, ChatTheme.gutter)
            .padding(.vertical, 18)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("hermes-group-transcript")
    }

    private func message(_ event: HermesGroupEvent, text: String) -> some View {
        let member = session.members.first { $0.id == event.actor.id }
        let author = session.author(of: event)
        return HStack(alignment: .top, spacing: 9) {
            if event.isOwnMessage { Spacer(minLength: 36) }
            else if event.actor.kind == "member" { GroupIdentityIcon(name: author, size: 30) }
            VStack(alignment: event.isOwnMessage ? .trailing : .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(author).font(.subheadline.weight(.semibold)).foregroundStyle(ChatTheme.ink)
                    Text(Date(timeIntervalSince1970: event.createdAt), style: .time)
                        .font(.caption2).foregroundStyle(ChatTheme.muted)
                }
                Text(verbatim: text)
                    .font(.body)
                    .foregroundStyle(ChatTheme.ink)
                    .textSelection(.enabled)
                    .padding(event.isOwnMessage ? 12 : 0)
                    .background(event.isOwnMessage ? ChatTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 17))
                    .accessibilityIdentifier("hermes-group-message-\(event.seq)")
            }
            if !event.isOwnMessage { Spacer(minLength: 18) }
        }
        .contextMenu {
            if session.pending == nil, event.payload.threadId != nil {
                Button("Reply in thread", systemImage: "arrowshape.turn.up.left") { session.reply = event; composing = true }
            }
            if session.pending == nil, event.actor.kind == "member", let member {
                Button("Mention @\(member.handle)", systemImage: "at") { mention(member.handle) }
            }
        }
    }

    @ViewBuilder
    private var statusCards: some View {
        if session.snapshot != nil, session.driver?.running != true {
            Label("The Hermes group driver is unavailable.", systemImage: "pause.circle")
                .font(.footnote).foregroundStyle(ChatTheme.muted)
        }
        if let driver = session.driver {
            ForEach(driver.memberActivity ?? []) { activity in
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(activity.tool.map { "\(session.label(for: activity.memberId)) · \($0)" } ??
                         "\(session.label(for: activity.memberId)) is \(activity.status == "queued" ? "queued" : activity.status == "stopping" ? "stopping" : "working")")
                        .font(.footnote).foregroundStyle(ChatTheme.muted)
                }
            }
            if driver.working && (driver.memberActivity?.isEmpty ?? true) {
                ProgressView("Bots are working…").controlSize(.small).foregroundStyle(ChatTheme.muted)
            }
            ForEach(driver.pendingActions ?? []) { action in
                if action.kind == "approval" { approvalCard(action) }
                else if action.kind == "retry", session.offers("retry") {
                    Button("Retry \(session.label(for: action.memberId))", systemImage: "arrow.clockwise") {
                        Task { await session.act(action) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(session.acting || session.sending)
                }
            }
            if !driver.working, session.offers("continue"), let pause = pausedDiscussion {
                Button("Continue discussion", systemImage: "play.circle") { Task { await session.resume(pause) } }
                    .buttonStyle(.bordered)
                    .disabled(session.acting || session.sending)
            }
        }
    }

    private func approvalCard(_ action: HermesGroupAction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(session.label(for: action.memberId)) needs approval", systemImage: "hand.raised")
                .font(.subheadline.weight(.semibold)).foregroundStyle(ChatTheme.attention)
            if let description = action.approval?.description, !description.isEmpty {
                Text(verbatim: description).font(.footnote)
            }
            if let command = action.approval?.command, !command.isEmpty {
                Text(verbatim: command).font(.footnote.monospaced()).textSelection(.enabled)
            }
            if session.offers("approve"), action.requestId != nil {
                HStack {
                    if action.approval?.choices?.contains("deny") == true {
                        Button("Deny") { Task { await session.act(action, choice: "deny") } }
                    }
                    if action.approval?.choices?.contains("once") == true, action.approval?.command?.isEmpty == false {
                        Button("Allow once") { Task { await session.act(action, choice: "once") } }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(session.acting || session.sending)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var pausedDiscussion: String? {
        guard let max = session.driver?.maxContinues else { return nil }
        var active: [String: HermesGroupEvent] = [:]
        var grants: [String: Int] = [:]
        for event in session.events {
            if event.kind == "room.stop_requested" { active.removeAll() }
            if event.kind == "message.user" {
                if let thread = event.payload.threadId { active[thread] = nil }
            }
            if let thread = event.payload.threadId, let discussion = event.payload.discussionEventId {
                if event.kind == "room.continued" {
                    grants[discussion, default: 0] += 1
                    active[thread] = nil
                }
                if event.kind == "room.activity", event.payload.status == "bounded", grants[discussion, default: 0] < max {
                    active[thread] = event
                }
            }
        }
        return active.values.max { $0.seq < $1.seq }?.payload.discussionEventId
    }

    private func notice(for event: HermesGroupEvent) -> String? {
        let author = event.payload.memberId.map { session.label(for: $0) } ?? "A bot"
        switch event.kind {
        case "turn.failed": return String("\(author) hit an error\((event.payload.error ?? event.payload.reason).map { " · \($0)" } ?? "")".prefix(500))
        case "turn.deferred", "member.unavailable": return "\(author) is unavailable"
        case "room.activity" where event.payload.status == "bounded": return "Discussion reached its round or message limit"
        case "room.stop_requested": return "Stop requested"
        case "room.continued": return "Discussion continued"
        default: return nil
        }
    }

    private var composer: some View {
        @Bindable var session = session
        return VStack(alignment: .leading, spacing: 7) {
            if let failure = session.actionError {
                Text(failure).font(.footnote).foregroundStyle(ChatTheme.warning)
            }
            if let reply = session.reply {
                HStack {
                    Label("Replying to \(session.author(of: reply))", systemImage: "arrowshape.turn.up.left")
                        .font(.caption).foregroundStyle(ChatTheme.muted)
                    Spacer()
                    Button("Cancel reply", systemImage: "xmark") { session.reply = nil }.labelStyle(.iconOnly)
                        .disabled(session.pending != nil)
                }
            }
            HStack(alignment: .bottom, spacing: 7) {
                Menu {
                    Button("Everyone (@all)") { mention("all") }
                    ForEach(session.members) { member in
                        Button("\(member.label) · @\(member.handle)") { mention(member.handle) }
                    }
                } label: {
                    Label("Mention a bot", systemImage: "at").labelStyle(.iconOnly)
                        .font(.headline).foregroundStyle(ChatTheme.muted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(session.members.isEmpty || session.pending != nil)
                TextField("Message group", text: $session.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.vertical, 11)
                    .focused($composing)
                    .disabled(session.pending != nil || session.sending)
                    .accessibilityIdentifier("hermes-group-composer")
                Button(session.pending != nil && !session.sending ? "Retry send" : "Send to group",
                       systemImage: session.pending != nil && !session.sending ? "arrow.clockwise" : "arrow.up") {
                    Task { await session.send() }
                }
                .labelStyle(.iconOnly)
                .font(.headline.weight(.semibold))
                .foregroundStyle(session.canSend ? ChatTheme.background : ChatTheme.muted)
                .frame(width: 34, height: 34)
                .background(session.canSend ? ChatTheme.ink : ChatTheme.surface, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .disabled(!session.canSend)
                .accessibilityIdentifier("send-hermes-group")
            }
            .padding(4)
            .background(ChatTheme.raised, in: RoundedRectangle(cornerRadius: 25))
            .overlay { RoundedRectangle(cornerRadius: 25).strokeBorder(ChatTheme.border).allowsHitTesting(false) }
        }
        .padding(.horizontal, ChatTheme.gutter)
        .padding(.vertical, 8)
    }

    private func mention(_ handle: String) {
        guard session.pending == nil else { return }
        if let last = session.draft.last, !last.isWhitespace { session.draft += " " }
        session.draft += "@\(handle) "
        composing = true
    }

    private var memberList: some View {
        NavigationStack {
            List(session.members) { member in
                HStack(spacing: 12) {
                    GroupIdentityIcon(name: member.label, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.label).font(.subheadline.weight(.semibold))
                        Text("@\(member.handle)").font(.caption).foregroundStyle(ChatTheme.muted)
                    }
                }
                .frame(minHeight: 44)
            }
            .navigationTitle("Group members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showingMembers = false } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct GroupIdentityIcon: View {
    let name: String
    let size: CGFloat

    var body: some View {
        let initials = name.prefix(2).uppercased()
        Text(initials)
            .font(.caption2.weight(.bold))
            .foregroundStyle(ChatTheme.sidebarAccent)
            .frame(width: size, height: size)
            .background(ChatTheme.sidebarAccent.opacity(0.13), in: Circle())
            .accessibilityHidden(true)
    }
}
