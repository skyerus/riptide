import AVFAudio
import CallKit
import Observation
import RiptideCore
import SwiftUI

struct CodexVoiceScreen: View {
    let call: CodexVoiceCallModel
    let agent: WorkspaceAgent?
    let minimize: () -> Void

    var body: some View {
        AgentCallScreen(call: call, agent: agent, context: call.chat?.title ?? "Temporary call",
                        accessibilityPrefix: "codex-voice", minimize: minimize) { EmptyView() }
    }
}

@MainActor
@Observable
final class CodexVoiceCallModel: VoiceCallControls {
    let id = UUID()
    let workspaceID: String
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
    private var status = "Calling…"
    private(set) var connected = false
    private(set) var muted = false
    private(set) var finished = false
    private(set) var audioRoute = VoiceCallAudioRoute()
    private var systemAudioActive = false
    private var held = false
    @ObservationIgnored private var mediaTask: Task<Void, Never>?
    @ObservationIgnored private var began = false
    @ObservationIgnored private var signaling: CodexLiveClient?
    @ObservationIgnored private var media: CodexVoiceMedia?
    @ObservationIgnored private var startupDeadline: Task<Void, Never>?

    var displayStatus: String { status }
    var canMute: Bool { connected && (!listenOnly || fixture) }
    var audioControlsEnabled: Bool { !finished && !held && (systemAudioActive || (fixture && connected)) }

    private var listenOnly: Bool {
        #if DEBUG && targetEnvironment(simulator)
        fixture || ProcessInfo.processInfo.environment["RIPTIDE_CODEX_VOICE_CHECK"] == "1"
        #else
        false
        #endif
    }

    init(endpoint: CodexLocalEndpoint, workspace: WorkspaceState, workspaceID: String,
         session: CodexWorkspaceSession? = nil) {
        self.endpoint = endpoint
        self.workspaceID = workspaceID
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
        status = "Connecting…"
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
        guard canMute else { return }
        if fixture {
            setMuted(!muted)
            return
        }
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
        refreshAudioRoute()
    }

    func refreshAudioRoute() {
        guard systemAudioActive else { return }
        audioRoute = VoiceCallAudioRoute.current()
    }

    func setAudioOutput(speaker: Bool, input: AVAudioSessionPortDescription?) {
        guard audioControlsEnabled, let media else { return }
        if fixture {
            audioRoute = VoiceCallAudioRoute(name: speaker ? "Speaker" : "iPhone",
                                            port: speaker ? .builtInSpeaker : .builtInReceiver)
            return
        }
        do { try media.selectSystemAudioOutput(speaker: speaker, input: input) }
        catch { status = "Couldn’t change audio output." }
        refreshAudioRoute()
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
            if listenOnly { muted = !fixture }
            status = listenOnly && !fixture ? "Connected · Microphone off" : "Connected"
            updateAudio()
            if !listenOnly { NativeCallSystem.shared.connected(self) }
            startupDeadline?.cancel()
        case .interrupted, .failed:
            finish("Voice connection lost. Start a new call to reconnect.")
        }
    }
}
