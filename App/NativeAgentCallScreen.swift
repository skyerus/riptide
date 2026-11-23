import AVFAudio
import Observation
import RiptideCore
import SwiftUI

struct NativeAgentCallScreen<Approvals: View>: View {
    let model: AgentChatModel
    let chatID: String
    let kind: RemoteKind
    let approvals: () -> Approvals
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var call: NativeAgentCall

    init(model: AgentChatModel, chatID: String, kind: RemoteKind, link: NativeVoiceLink,
         @ViewBuilder approvals: @escaping () -> Approvals) {
        self.model = model
        self.chatID = chatID
        self.kind = kind
        self.approvals = approvals
        _call = State(initialValue: NativeAgentCall(model: model, chatID: chatID, link: link))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "waveform")
                    .font(.title)
                    .foregroundStyle(ChatTheme.accent)
                    .frame(width: 64, height: 64)
                    .background(ChatTheme.surface, in: Circle())
                    .accessibilityHidden(true)
                Text(call.usesTalk ? "Hermes Talk" : "\(kind.name) voice").font(.title2.weight(.semibold))
                Text(call.status).font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("native-voice-status")
                Text("In \(model.title) · \(call.usesTalk ? "ChatGPT subscription" : "Host voice provider")")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 18) {
                    if !call.listenOnly {
                        Button(call.muted ? "Unmute" : "Mute", systemImage: call.muted ? "mic.slash" : "mic") {
                            call.toggleMute()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!call.connected)
                    }
                    Button(call.finished ? "Done" : "End call", systemImage: call.finished ? "checkmark" : "phone.down") {
                        call.end()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(call.finished ? ChatTheme.accent : .red)
                }
                approvals()
            }
            .multilineTextAlignment(.center)
            .padding(22)
            .frame(maxWidth: .infinity)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(ChatTheme.background)
        .task { await call.run() }
        .onDisappear { call.end() }
        .onChange(of: model.selected.loaded) {
            if !model.selected.loaded { call.end(message: "Chat disconnected.") }
        }
        .onChange(of: model.selectedID) {
            if model.selectedID != chatID { call.end(message: "Chat changed.") }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .background { call.end() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            if note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue {
                call.end(message: "Audio interrupted. Start a new call to reconnect.")
            }
        }
    }
}

@MainActor
@Observable
private final class NativeAgentCall {
    private let model: AgentChatModel
    private let chatID: String
    private let link: NativeVoiceLink
    private(set) var status = "Connecting…"
    private(set) var connected = false
    private(set) var muted = true
    private(set) var finished = false
    @ObservationIgnored private var media: CodexVoiceMedia?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var hermesEvents = HermesLiveEvents()
    @ObservationIgnored private var delegating = false

    var usesTalk: Bool {
        if case .hermesTalk = link { return true }
        return false
    }

    var listenOnly: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["RIPTIDE_NATIVE_VOICE_CHECK"] == "1"
        #else
        false
        #endif
    }

    init(model: AgentChatModel, chatID: String, link: NativeVoiceLink) {
        self.model = model
        self.chatID = chatID
        self.link = link
    }

    func run() async {
        guard !finished, media == nil, model.selectedID == chatID, model.selected.loaded else { return }
        do {
            if !listenOnly {
                guard await AVAudioApplication.requestRecordPermission() else { throw VoiceMediaError.microphoneDenied }
            }
            guard !finished, !Task.isCancelled else { return }
            deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(48))
                guard !Task.isCancelled, let self, !self.connected else { return }
                self.end(message: "Voice did not connect in time.")
            }
            let peer = CodexVoiceMedia(onState: { [weak self] state in self?.receive(state) },
                                       onData: { [weak self] data in self?.receiveHermes(data) })
            media = peer
            switch link {
            case .hermes(let hermes):
                let history = model.selected.transcript.entries.suffix(16).compactMap { entry -> HermesVoiceLine? in
                    guard case .message(let role, let text) = entry.content else { return nil }
                    return HermesVoiceLine(role: role, text: text)
                }
                let offer = try await peer.offer(listenOnly: listenOnly)
                try checkCurrent()
                let answer = try await hermes.answer(offer: offer, history: history)
                try checkCurrent()
                try await peer.accept(answer)
            case .hermesTalk(let talk):
                guard !model.selected.working, !model.selected.configuring, model.selected.permissions.isEmpty else {
                    throw ACPError.rejected("Finish the current chat turn before calling Hermes Talk.")
                }
                let offer = try await peer.offer(listenOnly: listenOnly)
                try checkCurrent()
                let answer = try await talk.answer(offer: offer, sessionID: chatID)
                try checkCurrent()
                try await peer.accept(answer)
                while !finished {
                    let activity = try await talk.poll()
                    try checkCurrent()
                    if connected, let activity {
                        switch activity {
                        case .listening: status = listenOnly ? "Connected · Microphone off" : "Connected"
                        case .working: status = "Hermes is working…"
                        case .result: status = "Hermes returned a result"
                        }
                    }
                    try await Task.sleep(for: .seconds(1))
                }
            case .openClaw(let claw):
                let session = try await model.openClawVoiceSessionKey(for: chatID)
                let offer = try await peer.offer(listenOnly: listenOnly, dataChannel: false)
                try checkCurrent()
                try await claw.start(offer: offer, sessionKey: session)
                for try await answer in claw.events {
                    try checkCurrent()
                    try await peer.accept(answer)
                }
                end()
            }
        } catch {
            if !Task.isCancelled && !finished { end(message: error.localizedDescription) }
        }
    }

    func toggleMute() {
        guard connected && !listenOnly else { return }
        muted.toggle()
        if muted { hermesEvents.clearInput() }
        media?.setMuted(muted)
        if case .hermes = link { media?.send(HermesLiveEvents.muteFrame(muted)) }
    }

    func end(message: String = "Call ended") {
        guard !finished else { return }
        let wasConnected = connected
        finished = true
        connected = false
        muted = true
        status = message
        deadline?.cancel()
        if case .hermes = link { media?.send(HermesLiveEvents.closeFrame()) }
        media?.close()
        media = nil
        if case .openClaw(let claw) = link { Task { await claw.end() } }
        if case .hermesTalk(let talk) = link {
            Task { [model, chatID] in
                await talk.end()
                if wasConnected { await model.refreshTalkHistory(in: chatID) }
            }
        }
    }

    private func checkCurrent() throws {
        try Task.checkCancellation()
        guard !finished, model.selectedID == chatID, model.selected.loaded else { throw NativeVoiceError.expired }
    }

    private func receive(_ state: CodexVoiceMedia.State) {
        guard !finished else { return }
        switch state {
        case .connected:
            guard !connected else { return }
            connected = true
            status = listenOnly ? "Connected · Microphone off" : "Connected"
            muted = listenOnly
            media?.setMuted(muted)
            deadline?.cancel()
        case .interrupted, .failed:
            end(message: "Voice connection lost.")
        }
    }

    private func receiveHermes(_ data: Data) {
        guard case .hermes = link, !finished else { return }
        switch hermesEvents.accept(data, listening: connected && !muted) {
        case .closed:
            end()
        case .delegation(let id, let text):
            if ["stop", "end call"].contains(text.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
                end()
                return
            }
            guard !delegating, !model.selected.working else {
                speak("Hermes is already working in this chat.", id: id)
                return
            }
            delegating = true
            status = "Hermes is working…"
            Task { [weak self, model, chatID] in
                do {
                    let reply = try await model.submitHermesVoice(text, in: chatID)
                    self?.speak(reply.isEmpty ? "Hermes finished without a spoken reply." : reply, id: id)
                } catch {
                    self?.speak("Hermes could not complete that request. Check the chat for details.", id: id)
                }
                guard let self, !self.finished else { return }
                self.delegating = false
                self.status = "Connected"
            }
        case nil:
            break
        }
    }

    private func speak(_ reply: String, id: String) {
        guard connected, !finished else { return }
        for frame in HermesLiveEvents.commentary(reply, delegationID: id) { media?.send(frame) }
    }
}
