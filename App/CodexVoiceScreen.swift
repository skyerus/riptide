import AVFAudio
import Observation
import RiptideCore
import SwiftUI

struct CodexVoiceScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var call: CodexVoiceCallModel
    private let chat: CodexChatSummary?

    init(endpoint: CodexLocalEndpoint, chat: CodexChatSummary? = nil, client: CodexLiveClient? = nil) {
        self.chat = chat
        _call = State(initialValue: CodexVoiceCallModel(endpoint: endpoint, chatID: chat?.id, client: client))
    }

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
            Text(chat.map { "Continuing “\($0.title)” using the host’s ChatGPT sign-in." }
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
                    call.end()
                    dismiss()
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationBackground(ChatTheme.background)
        .presentationDetents([.medium, .large])
        .task { await call.run() }
        .onDisappear { call.end() }
        .onChange(of: scenePhase) {
            if scenePhase == .background { call.end() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            if note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue {
                call.end(message: "Audio interrupted. Start a new call to reconnect.")
            }
        }
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
private final class CodexVoiceCallModel {
    private let endpoint: CodexLocalEndpoint
    private let chatID: String?
    private let chatClient: CodexLiveClient?
    private(set) var status = "Connecting…"
    private(set) var connected = false
    private(set) var muted = true
    private(set) var finished = false
    @ObservationIgnored private var signaling: CodexLiveClient?
    @ObservationIgnored private var media: CodexVoiceMedia?
    @ObservationIgnored private var startupDeadline: Task<Void, Never>?

    var listenOnly: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["RIPTIDE_CODEX_VOICE_CHECK"] == "1"
        #else
        false
        #endif
    }

    init(endpoint: CodexLocalEndpoint, chatID: String?, client: CodexLiveClient?) {
        self.endpoint = endpoint
        self.chatID = chatID
        chatClient = client
    }

    func run() async {
        guard !finished, signaling == nil else { return }
        do {
            if !listenOnly {
                guard await AVAudioApplication.requestRecordPermission() else { throw VoiceMediaError.microphoneDenied }
            }
            guard !finished, !Task.isCancelled else { return }
            let signaling = chatClient ?? endpoint.makeClient()
            let media = CodexVoiceMedia { [weak self] state in self?.handle(state) }
            self.signaling = signaling
            self.media = media
            startupDeadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(24))
                guard !Task.isCancelled, let self, !self.connected else { return }
                self.end(message: VoiceMediaError.network.localizedDescription)
            }
            let offer = try await media.offer(listenOnly: listenOnly)
            guard !finished, !Task.isCancelled else { return }
            let events = try await signaling.startSubscriptionCall(offer: offer, threadID: chatID)
            for try await event in events {
                guard !finished else { return }
                if case .answer(let answer) = event { try await media.accept(answer) }
            }
            end()
        } catch {
            if !Task.isCancelled { end(message: error.localizedDescription) }
        }
    }

    func toggleMute() {
        guard connected, !listenOnly else { return }
        muted.toggle()
        media?.setMuted(muted)
    }

    func end(message: String = "Call ended") {
        guard !finished else { return }
        finished = true
        connected = false
        muted = true
        status = message
        startupDeadline?.cancel()
        media?.close()
        media = nil
        if let signaling {
            self.signaling = nil
            Task { await signaling.endSubscriptionCall() }
        }
    }

    private func handle(_ state: CodexVoiceMedia.State) {
        guard !finished else { return }
        switch state {
        case .connected:
            guard !connected else { return }
            connected = true
            muted = listenOnly
            status = listenOnly ? "Connected · Microphone off" : "Connected"
            media?.setMuted(muted)
            startupDeadline?.cancel()
        case .interrupted, .failed:
            end(message: "Voice connection lost. Start a new call to reconnect.")
        }
    }
}
