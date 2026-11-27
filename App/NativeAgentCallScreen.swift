import AVFAudio
import Observation
import RiptideCore
import SwiftUI

struct NativeAgentCallScreen: View {
    let call: NativeAgentCall
    let agent: WorkspaceAgent?
    let minimize: () -> Void
    @State private var showingAudioRoutes = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 28)
                    caller
                    Spacer(minLength: 38)
                    call.approvals()
                    controls
                }
                .frame(maxWidth: 460, minHeight: max(0, geometry.size.height - 64))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 22)
                .padding(.vertical, 32)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background {
            ZStack(alignment: .top) {
                ChatTheme.background
                RadialGradient(colors: [ChatTheme.accent.opacity(0.16), .clear],
                               center: .top, startRadius: 15, endRadius: 390)
            }
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("native-call-screen")
        .interactiveDismissDisabled()
        .overlay(alignment: .topTrailing) {
            if !call.finished {
                Button("Minimize call", systemImage: "chevron.down", action: minimize)
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("minimize-voice-call")
                    .padding(12)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            call.refreshAudioRoute()
        }
        .confirmationDialog("Call audio", isPresented: $showingAudioRoutes, titleVisibility: .visible) {
            Button("iPhone") { call.setAudioOutput(speaker: false) }
            Button("Speaker") { call.setAudioOutput(speaker: true) }
            ForEach(call.externalInputs, id: \.uid) { input in
                Button(input.portName) { call.setAudioOutput(speaker: false, input: input) }
            }
        }
    }

    private var caller: some View {
        VStack(spacing: 11) {
            if let agent {
                AgentAvatar(agent: agent, size: 104)
                    .padding(.bottom, 10)
            }
            Text(call.name)
                .font(.largeTitle.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(call.displayStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("native-voice-status")
            if let connectedAt = call.connectedAt, !call.finished {
                Text(connectedAt, style: .timer)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("native-voice-duration")
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        HStack(alignment: .top, spacing: 0) {
            if !call.finished {
                callButton(call.muted ? "Unmute" : "Mute", symbol: call.muted ? "mic.slash.fill" : "mic.fill",
                           active: call.muted, identifier: "native-voice-mute") { call.toggleMute() }
                    .disabled(!call.connected || call.listenOnly)
            }
            callButton(call.finished ? "Done" : "End call",
                       symbol: call.finished ? "checkmark" : "phone.down.fill",
                       end: !call.finished, identifier: "native-voice-end") {
                if call.finished { minimize() }
                else { call.requestEnd() }
            }
            if !call.finished {
                callButton(call.externalInputs.isEmpty ? "Speaker" : "Audio", symbol: call.outputSymbol,
                           active: call.onSpeaker, identifier: "native-voice-audio") {
                    if call.externalInputs.isEmpty { call.setAudioOutput(speaker: !call.onSpeaker) }
                    else { showingAudioRoutes = true }
                }
                .disabled(!call.audioControlsEnabled)
                .accessibilityValue(call.outputName)
            }
        }
        .frame(maxWidth: 350)
    }

    private func callButton(_ title: String, symbol: String, active: Bool = false, end: Bool = false,
                            identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .medium))
                    .frame(width: end ? 72 : 60, height: 60)
                    .foregroundStyle(active ? .black : .white)
                    .background(end ? Color.red : active ? .white : ChatTheme.surface, in: Capsule())
                Text(title)
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

@MainActor
@Observable
final class NativeAgentCall: Identifiable, SystemVoiceCall {
    let id = UUID()
    let name: String
    let model: AgentChatModel
    let chatID: String
    let locator: WorkspaceChatID
    let approvals: () -> AnyView
    private let link: NativeVoiceLink
    private let voice: String?
    @ObservationIgnored private weak var workspace: WorkspaceState?
    @ObservationIgnored private var transcript = VoiceTranscript()
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var connectedInstant: ContinuousClock.Instant?
    private var status = "Calling…"
    private(set) var connectedAt: Date?
    private(set) var muted = false
    private(set) var finished = false
    private(set) var outputName = "iPhone"
    private(set) var outputSymbol = "speaker.wave.2.fill"
    private(set) var onSpeaker = false
    private(set) var externalInputs: [AVAudioSessionPortDescription] = []
    private var systemAudioActive = false
    private var held = false
    @ObservationIgnored private var began = false
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private var media: CodexVoiceMedia?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var hermesEvents = HermesLiveEvents()
    @ObservationIgnored private var delegating = false

    var connected: Bool { connectedAt != nil && !finished }
    var audioControlsEnabled: Bool { systemAudioActive && !held && !finished }

    var displayStatus: String {
        if connected && held { return "On hold" }
        if connected && !listenOnly && !systemAudioActive { return "Audio paused" }
        return status
    }

    var listenOnly: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["RIPTIDE_NATIVE_VOICE_CHECK"] == "1"
        #else
        false
        #endif
    }

    init(name: String, model: AgentChatModel, locator: WorkspaceChatID, link: NativeVoiceLink,
         workspace: WorkspaceState, approvals: @escaping () -> AnyView) {
        self.name = name
        self.model = model
        self.locator = locator
        chatID = locator.chat
        self.link = link
        self.workspace = workspace
        self.approvals = approvals
        let selected = workspace.calls.voice(for: locator.workspace)
        if case .hermesTalk(_, let allowsVoiceSelection) = link, allowsVoiceSelection, !selected.isEmpty { voice = selected }
        else { voice = nil }
    }

    func run() async {
        guard !finished, !began else { return }
        began = true
        model.setVoiceConnectionInUse(true)
        do {
            try checkCurrent()
            if case .hermesTalk = link,
               model.selected.working || model.selected.configuring || !model.selected.permissions.isEmpty {
                throw ACPError.rejected("Finish the current chat turn before calling Hermes Talk.")
            }
            if !listenOnly {
                guard await AVAudioApplication.requestRecordPermission() else { throw VoiceMediaError.microphoneDenied }
            }
            guard !finished, !Task.isCancelled else { return }
            if listenOnly { try startMedia(systemAudio: false) }
            else { try await NativeCallSystem.shared.start(self) }
        } catch {
            if !Task.isCancelled && !finished { finish(error.localizedDescription) }
        }
    }

    func startMedia(systemAudio: Bool) throws {
        let peer = CodexVoiceMedia(onState: { [weak self] state in self?.receive(state) },
                                   onData: { [weak self] data in self?.receiveHermes(data) })
        if systemAudio { try peer.prepareSystemAudio() }
        media = peer
        status = "Connecting…"
        startup = Task { await connect(peer) }
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(48))
            guard !Task.isCancelled, let self, !self.connected else { return }
            self.finish("Voice did not connect in time.")
        }
    }

    private func connect(_ peer: CodexVoiceMedia) async {
        do {
            try checkCurrent()
            switch link {
            case .hermes(let hermes):
                let history = model.recentMessages(in: chatID).compactMap { entry -> HermesVoiceLine? in
                    guard case .message(let role, let text) = entry.content else { return nil }
                    return HermesVoiceLine(role: role, text: text)
                }
                let offer = try await peer.offer(listenOnly: listenOnly)
                try checkCurrent()
                let answer = try await hermes.answer(offer: offer, history: history)
                try checkCurrent()
                try await peer.accept(answer)
            case .hermesTalk(let talk, _):
                let offer = try await peer.offer(listenOnly: listenOnly)
                try checkCurrent()
                let answer = try await talk.answer(offer: offer, sessionID: chatID, voice: voice)
                try checkCurrent()
                try await peer.accept(answer)
                while !finished {
                    let activity = try await talk.poll()
                    if finished { break }
                    try checkCurrent()
                    if connected, let activity {
                        switch activity {
                        case .listening: status = listenOnly ? "Connected · Microphone off" : "Connected"
                        case .working: status = "Hermes is working…"
                        case .result:
                            status = "Hermes returned a result"
                            await model.refreshTalkHistory(in: chatID)
                        }
                    }
                    try await Task.sleep(for: .seconds(1))
                }
                _ = try? await talk.poll()
            case .openClaw(let claw):
                let session = try await model.openClawVoiceSessionKey(for: chatID)
                let offer = try await peer.offer(listenOnly: listenOnly, dataChannel: false)
                try checkCurrent()
                try await claw.start(offer: offer, sessionKey: session)
                for try await answer in claw.events {
                    try checkCurrent()
                    try await peer.accept(answer)
                }
                finish()
            }
        } catch {
            if !Task.isCancelled && !finished { finish(error.localizedDescription) }
        }
    }

    func toggleMute() {
        guard connected && !listenOnly else { return }
        Task {
            do { try await NativeCallSystem.shared.requestMute(!muted, for: self) }
            catch { if !finished { status = "Couldn’t change microphone mute." } }
        }
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        updateMicrophone()
    }

    func setHeld(_ held: Bool) {
        self.held = held
        updateAudio()
    }

    func setSystemAudioActive(_ active: Bool) {
        systemAudioActive = active
        updateAudio()
        refreshAudioRoute()
    }

    func refreshAudioRoute() {
        let session = AVAudioSession.sharedInstance()
        externalInputs = (session.availableInputs ?? []).filter { $0.portType != .builtInMic }
        let output = session.currentRoute.outputs.first
        onSpeaker = output?.portType == .builtInSpeaker
        if output?.portType == .builtInReceiver { outputName = "iPhone" }
        else { outputName = output?.portName ?? "iPhone" }
        switch output?.portType {
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .headphones: outputSymbol = "headphones"
        default: outputSymbol = onSpeaker ? "speaker.wave.2.fill" : "speaker.wave.2"
        }
    }

    func setAudioOutput(speaker: Bool, input: AVAudioSessionPortDescription? = nil) {
        guard audioControlsEnabled, let media else { return }
        let destination = speaker ? nil : input ?? AVAudioSession.sharedInstance().availableInputs?
            .first(where: { $0.portType == .builtInMic })
        do { try media.selectSystemAudioOutput(speaker: speaker, input: destination) }
        catch { status = "Couldn’t change audio output." }
        refreshAudioRoute()
    }

    func requestEnd() {
        if listenOnly { finish(); return }
        Task {
            do { try await NativeCallSystem.shared.requestEnd(self) }
            catch { finish() }
            if media == nil { finish() }
        }
    }

    func finish(_ message: String? = nil) {
        guard !finished else { return }
        let record = connectedInstant.map { start in
            ChatCallRecord(id: id, chat: locator, anchor: .acpMessages(model.messageCount(in: chatID)),
                           endedAt: .now, duration: start.duration(to: clock.now).secondsValue, transcript: transcript.lines)
        }
        let startup = self.startup
        let drainTalk: Bool
        if case .hermesTalk = link { drainTalk = record != nil }
        else { drainTalk = false }
        finished = true
        muted = true
        status = message ?? "Call ended"
        if !drainTalk { startup?.cancel() }
        model.setVoiceConnectionInUse(false)
        deadline?.cancel()
        if case .hermes = link { media?.send(HermesLiveEvents.closeFrame()) }
        media?.close()
        media = nil
        if !listenOnly { NativeCallSystem.shared.ended(self, reason: message == nil ? .remoteEnded : .failed) }
        if let record { workspace?.calls.save(record) }
        workspace?.calls.finished(id, dismiss: message == nil)
        switch link {
        case .hermes:
            break
        case .openClaw(let claw):
            finishVoiceInBackground { [weak workspace, model, chatID] in
                let lines = await claw.end()
                if var record {
                    if !lines.isEmpty {
                        record.transcript = lines
                        workspace?.calls.save(record)
                    }
                    await model.refreshTalkHistory(in: chatID)
                }
            }
        case .hermesTalk(let talk, _):
            finishVoiceInBackground { [weak workspace, model, chatID] in
                if drainTalk { await startup?.value }
                let lines = await talk.end()
                if var record {
                    if !lines.isEmpty {
                        record.transcript = lines
                        workspace?.calls.save(record)
                    }
                    await model.refreshTalkHistory(in: chatID)
                }
            }
        }
    }

    private func checkCurrent() throws {
        try Task.checkCancellation()
        guard !finished, model.isLoaded(chatID) else { throw NativeVoiceError.expired }
    }

    private func updateAudio() {
        media?.setSystemAudioEnabled(audioControlsEnabled)
        updateMicrophone()
    }

    private func updateMicrophone() {
        let shouldMute = !connected || muted || !audioControlsEnabled
        if shouldMute { hermesEvents.clearInput() }
        media?.setMuted(shouldMute)
        if case .hermes = link { media?.send(HermesLiveEvents.muteFrame(shouldMute)) }
    }

    private func receive(_ state: CodexVoiceMedia.State) {
        guard !finished else { return }
        switch state {
        case .connected:
            guard !connected else { return }
            connectedAt = Date()
            connectedInstant = clock.now
            status = listenOnly ? "Connected · Microphone off" : "Connected"
            updateMicrophone()
            if !listenOnly { NativeCallSystem.shared.connected(self) }
            deadline?.cancel()
        case .interrupted, .failed:
            finish("Voice connection lost.")
        }
    }

    private func receiveHermes(_ data: Data) {
        guard case .hermes = link, !finished else { return }
        transcript.acceptHermesMedia(data, listening: connected && audioControlsEnabled && !muted)
        switch hermesEvents.accept(data, listening: connected && audioControlsEnabled && !muted) {
        case .closed:
            finish()
        case .delegation(let id, let text):
            guard !delegating, !model.workingChats.contains(chatID) else {
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
