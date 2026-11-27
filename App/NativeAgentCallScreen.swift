import AVFAudio
import Observation
import RiptideCore
import SwiftUI

@MainActor
protocol VoiceCallControls: SystemVoiceCall {
    var displayStatus: String { get }
    var muted: Bool { get }
    var canMute: Bool { get }
    var audioRoute: VoiceCallAudioRoute { get }
    var audioControlsEnabled: Bool { get }
    func toggleMute()
    func refreshAudioRoute()
    func setAudioOutput(speaker: Bool, input: AVAudioSessionPortDescription?)
    func requestEnd()
}

struct AgentCallScreen<Call: VoiceCallControls, Approvals: View>: View {
    let call: Call
    let agent: WorkspaceAgent?
    let context: String?
    let accessibilityPrefix: String
    let minimize: () -> Void
    @ViewBuilder let approvals: () -> Approvals
    @State private var showingAudioRoutes = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if !call.finished {
                    Button(action: minimize) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(.white.opacity(0.08), in: Circle())
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Minimize call")
                    .accessibilityIdentifier("minimize-voice-call")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)

            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 24) {
                        Spacer(minLength: 24)
                        caller
                        Spacer(minLength: 24)
                        approvals()
                        controls
                    }
                    .frame(maxWidth: 460, minHeight: max(0, geometry.size.height - 40))
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 40)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .background {
            ZStack(alignment: .top) {
                ChatTheme.background
                RadialGradient(colors: [ChatTheme.accent.opacity(0.16), .clear],
                               center: .top, startRadius: 15, endRadius: 390)
            }
            .ignoresSafeArea()
        }
        .onAppear { call.refreshAudioRoute() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            call.refreshAudioRoute()
        }
        .confirmationDialog("Call audio", isPresented: $showingAudioRoutes, titleVisibility: .visible) {
            Button("iPhone") { call.setAudioOutput(speaker: false, input: nil) }
            Button("Speaker") { call.setAudioOutput(speaker: true, input: nil) }
            ForEach(call.audioRoute.externalInputs, id: \.uid) { input in
                Button(input.portName) { call.setAudioOutput(speaker: false, input: input) }
            }
        }
    }

    private var caller: some View {
        VStack(spacing: 10) {
            Group {
                if let agent {
                    AgentAvatar(agent: agent, size: 100)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 38, weight: .medium))
                        .frame(width: 100, height: 100)
                        .background(ChatTheme.raised, in: Circle())
                }
            }
            .padding(.bottom, 8)
            .accessibilityHidden(true)
            Text(call.name)
                .font(.largeTitle.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(call.displayStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("\(accessibilityPrefix)-status")
            if let connectedAt = call.connectedAt, !call.finished {
                Text(connectedAt, style: .timer)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(accessibilityPrefix)-duration")
            }
            if let context {
                Text(context)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        VStack(spacing: 32) {
            if !call.finished {
                HStack(alignment: .top, spacing: 32) {
                    callButton(call.muted ? "Unmute" : "Mute",
                               symbol: call.muted ? "mic.slash.fill" : "mic.slash",
                               active: call.muted, identifier: "mute") { call.toggleMute() }
                        .disabled(!call.canMute)
                    callButton(call.audioRoute.externalInputs.isEmpty ? "Speaker" : "Audio", symbol: call.audioRoute.symbol,
                               active: call.audioRoute.onSpeaker, identifier: "audio") {
                        if call.audioRoute.externalInputs.isEmpty {
                            call.setAudioOutput(speaker: !call.audioRoute.onSpeaker, input: nil)
                        } else {
                            showingAudioRoutes = true
                        }
                    }
                    .disabled(!call.audioControlsEnabled)
                    .accessibilityValue(call.audioRoute.name)
                }
            }
            callButton(call.finished ? "Done" : "End Call",
                       symbol: call.finished ? "checkmark" : "phone.down.fill",
                       end: !call.finished, identifier: "end") {
                if call.finished { minimize() }
                else { call.requestEnd() }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func callButton(_ title: String, symbol: String, active: Bool = false, end: Bool = false,
                            identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: end ? 27 : 24, weight: .medium))
                    .frame(width: end ? 72 : 64, height: end ? 72 : 64)
                    .foregroundStyle(active ? .black : .white)
                    .background(end ? Color.red : active ? .white : ChatTheme.raised, in: Circle())
                Text(title)
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(.center)
            }
            .frame(minWidth: 76)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
        .accessibilityIdentifier("\(accessibilityPrefix)-\(identifier)")
    }
}

@MainActor
@Observable
final class NativeAgentCall: Identifiable, VoiceCallControls {
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
    private(set) var audioRoute = VoiceCallAudioRoute()
    private var systemAudioActive = false
    private var held = false
    @ObservationIgnored private var began = false
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private var media: CodexVoiceMedia?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var hermesEvents = HermesLiveEvents()
    @ObservationIgnored private var delegating = false

    var connected: Bool { connectedAt != nil && !finished }
    var canMute: Bool { connected && !listenOnly }
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
        guard canMute else { return }
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
        guard systemAudioActive else { return }
        audioRoute = VoiceCallAudioRoute.current()
    }

    func setAudioOutput(speaker: Bool, input: AVAudioSessionPortDescription?) {
        guard audioControlsEnabled, let media else { return }
        do { try media.selectSystemAudioOutput(speaker: speaker, input: input) }
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
