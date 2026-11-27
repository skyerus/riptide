import AVFAudio
import CallKit
import Observation
import RiptideCore
import SwiftUI

struct CodexVoiceScreen: View {
    let call: CodexVoiceCallModel
    let minimize: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 33, weight: .medium))
                    .foregroundStyle(ChatTheme.accent)
                    .frame(width: 80, height: 80)
                    .background(ChatTheme.surface, in: Circle())
                    .accessibilityHidden(true)
                Text("Codex voice").font(.title2.weight(.semibold))
                Text(call.status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("codex-voice-status")
            }
            if let connectedAt = call.connectedAt, !call.finished {
                Text(connectedAt, style: .timer)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(call.chat.map { "Continuing “\($0.title)” using the host’s ChatGPT sign-in." }
                 ?? "Uses the host’s ChatGPT sign-in. This call opens a separate temporary chat.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 24) {
                if !call.listenOnly {
                    control(call.muted ? "Unmute" : "Mute", symbol: call.muted ? "mic.slash.fill" : "mic.fill",
                            tint: ChatTheme.surface, identifier: "codex-voice-mute") {
                        call.toggleMute()
                    }
                    .disabled(!call.connected)
                }
                control(call.finished ? "Done" : "End call", symbol: call.finished ? "checkmark" : "phone.down.fill",
                        tint: call.finished ? ChatTheme.surface : .red.opacity(0.78), identifier: "codex-voice-end") {
                    if call.finished { minimize() }
                    else { call.requestEnd() }
                }
            }
        }
        .padding(28)
        .overlay(alignment: .topTrailing) {
            if !call.finished {
                Button("Minimize call", systemImage: "chevron.down", action: minimize)
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("minimize-voice-call")
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationBackground(ChatTheme.background)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()

    }

    private func control(_ label: String, symbol: String, tint: Color,
                         identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(tint, in: Circle())
                Text(label).font(.caption)
            }
            .frame(minWidth: 74)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

@MainActor
@Observable
final class CodexVoiceCallModel: SystemVoiceCall {
    let id = UUID()
    let chat: CodexChatSummary?
    let locator: WorkspaceChatID?
    let name: String
    private let endpoint: CodexLocalEndpoint
    private let chatClient: CodexLiveClient?
    private let voice: String?
    @ObservationIgnored private weak var workspace: WorkspaceState?
    @ObservationIgnored private weak var session: CodexWorkspaceSession?
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var connectedInstant: ContinuousClock.Instant?
    private(set) var connectedAt: Date?
    private(set) var status = "Connecting…"
    private(set) var connected = false
    private(set) var muted = true
    private(set) var finished = false
    private var systemAudioActive = false
    private var held = false
    @ObservationIgnored private var mediaTask: Task<Void, Never>?
    @ObservationIgnored private var began = false
    @ObservationIgnored private var signaling: CodexLiveClient?
    @ObservationIgnored private var media: CodexVoiceMedia?
    @ObservationIgnored private var startupDeadline: Task<Void, Never>?

    var listenOnly: Bool {
        #if DEBUG && targetEnvironment(simulator)
        fixture || ProcessInfo.processInfo.environment["RIPTIDE_CODEX_VOICE_CHECK"] == "1"
        #else
        false
        #endif
    }

    init(endpoint: CodexLocalEndpoint, workspace: WorkspaceState, workspaceID: String,
         session: CodexWorkspaceSession? = nil) {
        self.endpoint = endpoint
        self.workspace = workspace
        self.session = session
        chat = session?.chat
        locator = session?.locator
        chatClient = session?.client
        name = workspace.agent(workspaceID)?.name ?? "Codex"
        let selected = workspace.calls.voice(for: workspaceID)
        voice = selected.isEmpty ? nil : selected
    }

    private var fixture: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["RIPTIDE_VOICE_FIXTURE"] == "1"
        #else
        false
        #endif
    }

    func run() async {
        guard !finished, !began else { return }
        began = true
        do {
            if !listenOnly {
                guard await AVAudioApplication.requestRecordPermission() else { throw VoiceMediaError.microphoneDenied }
            }
            guard !finished, !Task.isCancelled else { return }
            if listenOnly { try startMedia(systemAudio: false) }
            else { try await NativeCallSystem.shared.start(self) }
        } catch {
            if !Task.isCancelled { finish(error.localizedDescription) }
        }
    }

    func startMedia(systemAudio: Bool) throws {
        let media = CodexVoiceMedia { [weak self] state in self?.handle(state) }
        if systemAudio { try media.prepareSystemAudio() }
        self.media = media
        mediaTask = Task { await connect(media) }
        startupDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(24))
            guard !Task.isCancelled, let self, !self.connected else { return }
            self.finish(VoiceMediaError.network.localizedDescription)
        }
    }

    private func connect(_ media: CodexVoiceMedia) async {
        guard !finished else { return }
        let signaling = chatClient ?? endpoint.makeClient()
        self.signaling = signaling
        do {
            let offer = fixture ? "v=0 fixture" : try await media.offer(listenOnly: listenOnly)
            guard !finished, !Task.isCancelled else { return }
            let events = try await signaling.startSubscriptionCall(offer: offer, threadID: chat?.id, voice: voice)
            for try await event in events {
                guard !finished else { return }
                if case .answer(let answer) = event {
                    if fixture { handle(.connected) }
                    else { try await media.accept(answer) }
                }
            }
            finish(nil)
        } catch {
            if !Task.isCancelled { finish(error.localizedDescription) }
        }
    }

    func toggleMute() {
        guard connected, !listenOnly else { return }
        Task {
            do { try await NativeCallSystem.shared.requestMute(!muted, for: self) }
            catch { if !finished { status = "Couldn’t change microphone mute." } }
        }
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        updateAudio()
    }

    func setHeld(_ held: Bool) {
        self.held = held
        updateAudio()
    }

    func setSystemAudioActive(_ active: Bool) {
        systemAudioActive = active
        updateAudio()
    }

    private func updateAudio() {
        let active = systemAudioActive && !held && !finished
        media?.setSystemAudioEnabled(active)
        media?.setMuted(!active || !connected || muted)
        if connected && !listenOnly {
            status = held ? "On hold" : active ? "Connected" : "Audio paused"
        }
    }

    func requestEnd() {
        if listenOnly { finish(nil); return }
        Task {
            do { try await NativeCallSystem.shared.requestEnd(self) }
            catch { finish(nil) }
            if media == nil { finish(nil) }
        }
    }

    func finish(_ message: String?) {
        guard !finished else { return }
        finished = true
        connected = false
        muted = true
        status = message ?? "Call ended"
        startupDeadline?.cancel()
        mediaTask?.cancel()
        let peer = media
        media = nil
        peer?.setMuted(true)
        peer?.setSystemAudioEnabled(false)
        if !listenOnly { NativeCallSystem.shared.ended(self, reason: message == nil ? .remoteEnded : .failed) }
        let turn = session?.turns.last
        let anchor = ChatCallRecord.Anchor.codexMessage(turn: turn?.id, after: turn?.visibleMessages(isActive: false).last?.id)
        let record = locator.flatMap { locator in
            connectedInstant.map { start in
                ChatCallRecord(id: id, chat: locator, anchor: anchor, endedAt: .now,
                               duration: start.duration(to: clock.now).secondsValue, transcript: [])
            }
        }
        if let record { workspace?.calls.save(record) }
        if let signaling {
            self.signaling = nil
            workspace?.calls.setClosingCodex(true)
            finishVoiceInBackground { [weak workspace] in
                let lines = await signaling.endSubscriptionCall()
                peer?.close()
                workspace?.calls.setClosingCodex(false)
                if var record, !lines.isEmpty {
                    record.transcript = lines
                    workspace?.calls.save(record)
                }
            }
        } else {
            peer?.close()
        }
        workspace?.calls.finished(id, dismiss: message == nil)
    }

    private func handle(_ state: CodexVoiceMedia.State) {
        guard !finished else { return }
        switch state {
        case .connected:
            guard !connected else { return }
            connected = true
            connectedAt = .now
            connectedInstant = clock.now
            muted = listenOnly
            status = listenOnly ? "Connected · Microphone off" : "Connected"
            updateAudio()
            if !listenOnly { NativeCallSystem.shared.connected(self) }
            startupDeadline?.cancel()
        case .interrupted, .failed:
            finish("Voice connection lost. Start a new call to reconnect.")
        }
    }
}
