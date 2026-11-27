import AVFAudio
import Observation
import RiptideCore
import SwiftUI

struct ChatCallRecord: Codable, Identifiable {
    enum Anchor: Codable, Equatable {
        case codexMessage(turn: String?, after: String?)
        case acpMessages(Int)
    }

    let id: UUID
    let chat: WorkspaceChatID
    let anchor: Anchor
    let endedAt: Date
    let duration: TimeInterval
    var transcript: [VoiceTranscriptLine]

    var durationLabel: String {
        Duration.seconds(max(0, duration)).formatted(.time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

@MainActor
@Observable
final class WorkspaceVoiceCalls {
    enum Call: Identifiable {
        case codex(CodexVoiceCallModel)
        case native(NativeAgentCall)

        var id: UUID {
            switch self {
            case .codex(let call): call.id
            case .native(let call): call.id
            }
        }

        var chat: WorkspaceChatID? {
            switch self {
            case .codex(let call): call.locator
            case .native(let call): call.locator
            }
        }

        var name: String {
            switch self {
            case .codex(let call): call.name
            case .native(let call): call.name
            }
        }

        @MainActor var connectedAt: Date? {
            switch self {
            case .codex(let call): call.connectedAt
            case .native(let call): call.connectedAt
            }
        }

        @MainActor var finished: Bool {
            switch self {
            case .codex(let call): call.finished
            case .native(let call): call.finished
            }
        }

        @MainActor func end() {
            switch self {
            case .codex(let call): call.requestEnd()
            case .native(let call): call.requestEnd()
            }
        }
    }

    private let defaults: UserDefaults
    private let file: URL
    private var records: [ChatCallRecord]
    private var voices: [String: String]
    private(set) var active: Call?
    private var expanded = false
    private var closingCodex = false
    @ObservationIgnored private var forgotten = Set<String>()
    private(set) var saveFailure: WorkspaceChatID?

    var presentation: Call? {
        get { expanded ? active : nil }
        set {
            if newValue == nil {
                expanded = false
                if active?.finished == true { active = nil }
            }
        }
    }

    init(defaults: UserDefaults, namespace: UUID?) {
        self.defaults = defaults
        let directory = URL.applicationSupportDirectory.appending(path: "RiptideCalls", directoryHint: .isDirectory)
        file = directory.appending(path: namespace?.uuidString ?? "history").appendingPathExtension("json")
        records = (try? JSONDecoder().decode([ChatCallRecord].self, from: Data(contentsOf: file))) ?? []
        voices = defaults.dictionary(forKey: "voice.preferences") as? [String: String] ?? [:]
    }

    func canOpen(chat: WorkspaceChatID? = nil) -> Bool {
        !closingCodex && (active == nil || (chat != nil && active?.chat == chat))
    }

    func present(_ call: Call) {
        guard !closingCodex else { return }
        guard active == nil else {
            if active?.chat == call.chat { expanded = true }
            return
        }
        active = call
        expanded = true
        Task {
            switch call {
            case .codex(let model): await model.run()
            case .native(let model): await model.run()
            }
        }
    }

    func resume() { if active != nil { expanded = true } }

    func setClosingCodex(_ closing: Bool) { closingCodex = closing }

    func finished(_ id: UUID, dismiss: Bool) {
        guard active?.id == id, dismiss || !expanded else { return }
        presentation = nil
    }

    func records(in chat: WorkspaceChatID?) -> [ChatCallRecord] {
        guard let chat else { return [] }
        return records.filter { $0.chat == chat }
    }

    func save(_ record: ChatCallRecord) {
        guard !forgotten.contains(record.chat.workspace) else { return }
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
        else { records.append(record) }
        persist(chat: record.chat)
    }

    func voice(for workspace: String) -> String { voices[workspace] ?? "" }

    func setVoice(_ voice: String, for workspace: String) {
        voices[workspace] = voice.isEmpty ? nil : voice
        defaults.set(voices, forKey: "voice.preferences")
    }

    func forget(_ workspace: String) {
        forgotten.insert(workspace)
        if active?.chat?.workspace == workspace { active?.end() }
        records.removeAll { $0.chat.workspace == workspace }
        persist(chat: nil)
        setVoice("", for: workspace)
    }

    private func persist(chat: WorkspaceChatID?) {
        do {
            var directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var attributes = URLResourceValues()
            attributes.isExcludedFromBackup = true
            try directory.setResourceValues(attributes)
            try JSONEncoder().encode(records).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            saveFailure = nil
        } catch {
            saveFailure = chat
        }
    }
}

struct VoiceCallBar: View {
    let call: WorkspaceVoiceCalls.Call
    let resume: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: resume) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .foregroundStyle(ChatTheme.sidebarAccent)
                    Text(call.name).lineLimit(1)
                    if let connectedAt = call.connectedAt {
                        Text(connectedAt, style: .timer).monospacedDigit()
                    } else {
                        Text("Connecting…")
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up").font(.caption.weight(.semibold))
                }
                .font(.subheadline.weight(.medium))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Return to call with \(call.name)")
            .accessibilityIdentifier("resume-voice-call")
            Button("End call", systemImage: "phone.down.fill") { call.end() }
                .labelStyle(.iconOnly)
                .foregroundStyle(.red)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("end-minimized-call")
        }
        .buttonStyle(.plain)
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .background(.regularMaterial)
    }
}

struct ChatCallReceipt: View {
    let record: ChatCallRecord

    var body: some View {
        if record.transcript.isEmpty {
            header
        } else {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(record.transcript.enumerated()), id: \.offset) { _, line in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(line.role == .user ? "You" : "Agent")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(verbatim: line.text).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
                .font(.subheadline)
                .accessibilityIdentifier("call-transcript")
            } label: { header }
            .accessibilityHint("Show call transcript")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Call ended", systemImage: "phone.down")
                .font(.subheadline.weight(.medium))
            Spacer()
            Text(record.durationLabel)
                .monospacedDigit()
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-call-ended")
    }
}

struct AgentVoiceSettings: View {
    let workspaceID: String
    let availableVoices: (() async throws -> [String])?
    var pair: (() -> Void)?
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var options: [String] = []
    @State private var loading = true
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                if availableVoices != nil {
                    Section {
                        if loading { ProgressView("Loading voices…") }
                        else if let failure { Text(failure).foregroundStyle(.secondary) }
                        else if !options.isEmpty {
                            Picker("Voice", selection: Binding(
                                get: { options.contains(workspace.calls.voice(for: workspaceID)) ? workspace.calls.voice(for: workspaceID) : "" },
                                set: { workspace.calls.setVoice($0, for: workspaceID) }
                            )) {
                                Text("Host default").tag("")
                                ForEach(options, id: \.self) { voice in Text(voice.capitalized).tag(voice) }
                            }
                            .accessibilityIdentifier("agent-voice-picker")
                        } else {
                            Text("This voice route uses the host’s configured voice.").foregroundStyle(.secondary)
                        }
                    } footer: {
                        if !options.isEmpty { Text("Applies when you start the next call.") }
                    }
                } else {
                    Text("This voice route uses the host’s configured voice.").foregroundStyle(.secondary)
                }
                if let pair { Button("Pair voice route…", action: pair) }
            }
            .navigationTitle("Voice settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                guard let availableVoices else { return }
                do {
                    options = try await availableVoices().filter { !$0.isEmpty }.reduce(into: []) {
                        if !$0.contains($1) { $0.append($1) }
                    }
                    if !options.isEmpty, !options.contains(workspace.calls.voice(for: workspaceID)) {
                        workspace.calls.setVoice("", for: workspaceID)
                    }
                } catch {
                    if !Task.isCancelled { failure = "Couldn’t load the host’s voices." }
                }
                loading = false
            }
        }
    }
}

extension Duration {
    var secondsValue: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

@MainActor
func finishVoiceInBackground(_ finish: @escaping @MainActor () async -> Void) {
    let application = UIApplication.shared
    var background = UIBackgroundTaskIdentifier.invalid
    let end = {
        guard background != .invalid else { return }
        application.endBackgroundTask(background)
        background = .invalid
    }
    background = application.beginBackgroundTask(withName: "Save voice call", expirationHandler: end)
    Task {
        defer { end() }
        await finish()
    }
}
