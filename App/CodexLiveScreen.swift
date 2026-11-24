import RiptideCore
import SwiftUI

struct CodexLiveScreen: View {
    let endpoint: CodexLocalEndpoint
    @State private var showVoice = false
    @State private var client: CodexLiveClient?
    @State private var turn: CodexLiveTurn?
    @State private var status = "Joining the running turn…"
    @State private var active = false
    @State private var failure: String?
    @State private var attempt = 0
    @State private var draft = ""
    @State private var steering = false
    @State private var receipt: String?
    @State private var output = ""
    @State private var outputEvents = 0
    @State private var replies: [Reply] = []
    @State private var patch: String?
    @State private var viewport = TranscriptViewport()
    @FocusState private var editorFocused: Bool

    private struct Reply: Identifiable {
        let id: String
        var text: String
        var finished: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(status).font(.headline)
                            .foregroundStyle(active ? ChatTheme.accent : Color.primary)
                            .accessibilityIdentifier("codex-turn-status")
                        if let turn {
                            Text("\(turn.model ?? "Codex") · Turn \(turn.turnID.suffix(8))")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("codex-turn-id")
                        }
                    }
                    if let prompt = turn?.prompt {
                        Text(prompt)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if outputEvents > 0 {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Live output · \(outputEvents) updates")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("codex-live-updates")
                            Text(output.trimmingCharacters(in: .newlines))
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("codex-live-output")
                        }
                        .padding(12)
                        .background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    ForEach(replies) { reply in
                        ChatMarkdown(source: reply.text, streaming: active && !reply.finished)
                            .accessibilityIdentifier("codex-assistant-reply")
                    }
                    if let patch, !patch.isEmpty {
                        DisclosureGroup("Changes") {
                            DiffPreview(source: patch, title: "Turn diff")
                                .padding(.top, 8)
                        }
                        .font(.subheadline)
                    }
                    if let receipt {
                        Text(receipt).font(.footnote).foregroundStyle(ChatTheme.accent)
                            .accessibilityIdentifier("codex-steer-receipt")
                    }
                    if let failure {
                        Text(failure).font(.footnote).foregroundStyle(.secondary)
                        if !active {
                            Button("Join running turn") { attempt += 1 }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("codex-reconnect")
                        }
                    }
                }
                .transcriptColumn()
            }
            .scrollDismissesKeyboard(.interactively)
            .transcriptViewport($viewport, chat: nil)
            if active { composer }
        }
        .background(ChatTheme.background.ignoresSafeArea())
        .navigationTitle("Codex on this Mac")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink {
                    CodexChatsScreen(endpoint: endpoint, name: "Chats")
                } label: {
                    Label("Saved chats", systemImage: "bubble.left.and.bubble.right").labelStyle(.iconOnly)
                }
                .accessibilityIdentifier("saved-codex-chats")
                Button("Call Codex", systemImage: "phone") { showVoice = true }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("call-codex")
            }
        }
        .sheet(isPresented: $showVoice) { CodexVoiceScreen(endpoint: endpoint) }
        .task(id: attempt) { await watch() }
    }

    private var composer: some View {
        let prompt = "Steer this turn"
        let disabled = steering || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return ComposerSurface(focused: editorFocused) {
            TextField(prompt, text: $draft, prompt: Text(prompt).foregroundStyle(ChatTheme.muted), axis: .vertical)
                .lineLimit(1...6)
                .focused($editorFocused)
                .accessibilityIdentifier("codex-steer-input")
        } actions: {
            ComposerAction("Steer", symbol: "arrow.up", disabled: disabled) {
                editorFocused = false
                Task { await steer() }
            }
            .accessibilityIdentifier("codex-steer-send")
        }
    }

    private func watch() async {
        viewport.restore(nil)
        let peer = endpoint.makeClient()
        client = peer
        turn = nil
        active = false
        status = "Joining the running turn…"
        failure = nil
        receipt = nil
        output = ""
        outputEvents = 0
        replies = []
        patch = nil
        do {
            let joined = try await peer.attach()
            turn = joined
            active = true
            status = "Watching a turn already in progress"
            for try await event in peer.events {
                switch event {
                case .output(_, let text):
                    output = String((output + text).suffix(3_000))
                    outputEvents += 1
                case .assistantDelta(_, let itemID, let text):
                    updateReply(itemID, text: text, appending: true)
                case .assistantCompleted(_, let itemID, let text):
                    updateReply(itemID, text: text, appending: false)
                case .diff(_, let update):
                    patch = update
                case .completed(_, let outcome):
                    status = outcome == "completed" ? "Turn completed" : "Turn \(outcome)"
                    active = false
                    await peer.close()
                    return
                }
            }
        } catch {
            if !Task.isCancelled {
                status = (error as? CodexLiveError) == .noActiveTurn
                    ? "No active chat turn" : (turn == nil ? "Couldn’t join a turn" : "Connection closed")
                failure = error.localizedDescription
            }
        }
        active = false
        await peer.close()
    }

    private func updateReply(_ id: String, text: String, appending: Bool) {
        if let index = replies.firstIndex(where: { $0.id == id }) {
            replies[index].text = appending ? replies[index].text + text : text
            replies[index].finished = !appending
        } else {
            replies.append(Reply(id: id, text: text, finished: !appending))
        }
    }

    private func steer() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, let turn, active, !steering, !text.isEmpty else { return }
        steering = true
        failure = nil
        defer { steering = false }
        do {
            let acceptedTurnID = try await client.steer(text, expected: turn)
            receipt = "Steering accepted · Turn \(acceptedTurnID.suffix(8))"
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
        } catch {
            failure = error.localizedDescription
        }
    }
}
