import AVFoundation
import RiptideCore
import SwiftUI

typealias DictationTranscriber = @Sendable (Data) async throws -> String

struct MessageComposer<Options: View, Actions: View>: View {
    @Binding var focused: Bool
    let prompt: String
    let editorIdentifier: String
    let editorEnabled: Bool
    let chatID: String?
    let canDictate: Bool
    @Binding var draft: String
    @Binding var attachments: [ChatAttachment]
    let acceptsImages: Bool
    let attachmentByteLimit: Int
    let canAttach: Bool
    let transcribe: DictationTranscriber?
    let dismissKeyboard: () -> Void
    let canSubmit: Bool
    let submitDraft: () -> Void
    let queueDraft: (() -> Void)?
    @ViewBuilder let options: () -> Options
    @ViewBuilder let actions: (_ canSend: Bool) -> Actions

    @Environment(\.scenePhase) private var scenePhase
    @State private var dictation = ComposerDictation()
    @State private var importingAttachments = false
    @State private var clipboard: [NSItemProvider] = []

    var body: some View {
        ComposerSurface(focused: focused && !dictation.active, showsOptions: !dictation.active) {
            if dictation.active {
                recordingDisplay
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ComposerAttachmentStrip(attachments: $attachments)
                    ComposerEditor(text: $draft, focused: $focused, prompt: prompt,
                                   identifier: editorIdentifier, enabled: editorEnabled) { provider in
                        if canAttach { clipboard.append(provider) }
                    }
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text(prompt)
                                .font(.body)
                                .foregroundStyle(ChatTheme.muted)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        } options: {
            ComposerAttachmentPicker(attachments: $attachments, isImporting: $importingAttachments,
                                     clipboard: $clipboard, acceptsImages: acceptsImages, byteLimit: attachmentByteLimit, disabled: !canAttach)
                .id(chatID)
            options()
        } actions: {
            if dictation.active {
                control("Cancel dictation", symbol: "xmark", identifier: "dictation-cancel", action: dictation.cancel)
                if dictation.canFinish, let transcribe {
                    control("Stop dictation", symbol: "stop.fill", identifier: "dictation-stop") {
                        dictation.finish(transcribe: transcribe, insert: insert)
                    }
                    let queue = queueDraft.map { enqueue in
                        { finish(transcribe, then: enqueue) }
                    }
                    ComposerAction("Send", symbol: "arrow.up", disabled: !canSubmit || importingAttachments, queue: queue) {
                        finish(transcribe, then: submitDraft)
                    }
                    .accessibilityIdentifier("dictation-send")
                }
            } else {
                if transcribe != nil {
                    control("Dictate", symbol: "mic", identifier: "dictation-start", disabled: !canDictate || importingAttachments) {
                        dismissKeyboard()
                        dictation.start()
                    }
                }
                actions(canSubmit && !importingAttachments &&
                        (!attachments.isEmpty || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .task(id: dictation.recording) {
            while !Task.isCancelled, dictation.recording {
                if dictation.sample() {
                    dictation.stopRecording()
                    break
                }
                do { try await Task.sleep(for: .milliseconds(90)) } catch { break }
            }
        }
        .onChange(of: chatID) {
            clipboard = []
            reset()
        }
        .onChange(of: canDictate) { if !canDictate { reset() } }
        .onChange(of: scenePhase) { if scenePhase == .background { reset() } }
        .onDisappear(perform: reset)
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            if dictation.recording, note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ==
                AVAudioSession.InterruptionType.began.rawValue {
                dictation.cancel()
                dictation.error = "Recording was interrupted. Tap Dictate to start again."
            }
        }
        .alert("Dictation", isPresented: Binding(
            get: { dictation.error != nil },
            set: { if !$0 { dictation.error = nil } }
        )) {
            Button("OK", role: .cancel) { dictation.error = nil }
        } message: {
            Text(dictation.error ?? "")
        }
    }

    private var recordingDisplay: some View {
        HStack(spacing: 9) {
            if dictation.canFinish {
                Circle()
                    .fill(dictation.recording ? Color.red : ChatTheme.muted)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(dictation.elapsed, format: .time(pattern: .minuteSecond))
                    .monospacedDigit()
                    .accessibilityHidden(true)
                GeometryReader { geometry in
                    let spacing = 3.0
                    let count = max(1, Int(geometry.size.width / (3 + spacing)))
                    HStack(spacing: spacing) {
                        ForEach(Array(dictation.levels.suffix(count).enumerated()), id: \.offset) { _, level in
                            Capsule()
                                .fill(ChatTheme.sidebarAccent)
                                .frame(width: 3, height: 3 + level * 19)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
                .frame(height: 22)
                .accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.small)
                Text(dictation.activeLabel)
                    .lineLimit(1)
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dictation.activeLabel)
        .accessibilityIdentifier("dictation-status")
    }

    private func control(_ title: String, symbol: String, identifier: String, disabled: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "stop.fill" ? 12 : 16, weight: .medium))
                .foregroundStyle(ChatTheme.muted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    private func insert(_ transcript: String) {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = transcript
        } else {
            if draft.last?.isWhitespace == false { draft += " " }
            draft += transcript
        }
    }

    private func finish(_ transcribe: @escaping DictationTranscriber, then action: @escaping () -> Void) {
        dictation.finish(transcribe: transcribe) { transcript in
            insert(transcript)
            action()
        }
    }


    private func reset() {
        dictation.cancel()
        dictation.error = nil
    }
}

@MainActor
@Observable
private final class ComposerDictation {
    private enum Phase { case idle, preparing, recording, recorded, transcribing }
    private var phase: Phase = .idle
    private var task: Task<Void, Never>?
    private var recorder: AVAudioRecorder?
    private var recordingStarted: ContinuousClock.Instant?
    private var recordingURL: URL?
    private var sessionActive = false

    var error: String?
    private(set) var levels: [CGFloat] = []
    private(set) var elapsed: Duration = .zero
    var active: Bool { phase != .idle }
    var recording: Bool { phase == .recording }
    var canFinish: Bool { recording || phase == .recorded }
    var activeLabel: String {
        switch phase {
        case .idle: ""
        case .preparing: "Starting microphone…"
        case .recording: "Recording dictation"
        case .recorded: "Recording ready"
        case .transcribing: "Transcribing…"
        }
    }

    func start() {
        guard !active else { return }
        phase = .preparing
        task = Task {
            #if DEBUG
            if DictationFixture.transcribe != nil {
                beginRecording()
                return
            }
            #endif
            let allowed = await AVAudioApplication.requestRecordPermission()
            guard !Task.isCancelled else { return }
            guard allowed else {
                phase = .idle
                error = "Allow microphone access for Riptide in Settings to use dictation."
                return
            }
            do {
                let audio = AVAudioSession.sharedInstance()
                try audio.setCategory(.record, mode: .measurement)
                try audio.setActive(true)
                sessionActive = true
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("riptide-dictation-\(UUID().uuidString).m4a")
                recordingURL = url
                let input = try AVAudioRecorder(url: url, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000,
                    AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000
                ])
                recorder = input
                input.isMeteringEnabled = true
                guard input.record(forDuration: CodexDictation.maximumDuration) else {
                    throw CodexDictationError.invalidAudio
                }
                beginRecording()
            } catch {
                cancel()
                self.error = "Couldn’t start the microphone. Try again."
            }
        }
    }

    private func beginRecording() {
        elapsed = .zero
        levels = Array(repeating: 0, count: 64)
        recordingStarted = .now
        phase = .recording
    }

    func sample() -> Bool {
        guard let recordingStarted else { return false }
        elapsed = recordingStarted.duration(to: .now)
        recorder?.updateMeters()
        let power = recorder?.averagePower(forChannel: 0) ?? -32
        levels.removeFirst()
        levels.append(CGFloat(min(1, max(0, (power + 55) / 55))))
        let limit = DictationFixture.recordingLimit ?? CodexDictation.maximumDuration
        return elapsed >= .seconds(limit) || recorder?.isRecording == false
    }

    func stopRecording() {
        guard recording else { return }
        stopMicrophone()
        phase = .recorded
    }

    func finish(transcribe: @escaping DictationTranscriber, insert: @escaping (String) -> Void) {
        guard canFinish else { return }
        stopRecording()
        let url = recordingURL
        recordingURL = nil
        phase = .transcribing
        task = Task {
            do {
                let audio: Data
                do {
                    defer { if let url { try? FileManager.default.removeItem(at: url) } }
                    audio = try url.map { try Data(contentsOf: $0) } ?? Data()
                }
                try Task.checkCancellation()
                let transcript = try await transcribe(audio)
                guard !Task.isCancelled else { return }
                insert(transcript)
                phase = .idle
            } catch {
                guard !Task.isCancelled else { return }
                phase = .idle
                self.error = error.localizedDescription
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        stopMicrophone()
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
        phase = .idle
    }

    private func stopMicrophone() {
        recorder?.stop()
        recorder = nil
        recordingStarted = nil
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
    }
}

enum DictationFixture {
    static let recordingLimit: TimeInterval? = {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["RIPTIDE_DICTATION_FIXTURE"] == "1",
           let seconds = environment["RIPTIDE_DICTATION_FIXTURE_LIMIT"].flatMap(Double.init),
           seconds.isFinite, seconds > 0 {
            return seconds
        }
        #endif
        return nil
    }()

    static let transcribe: DictationTranscriber? = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["RIPTIDE_DICTATION_FIXTURE"] == "1" {
            return { _ in
                try await Task.sleep(for: .milliseconds(500))
                return "Add a quick summary of the open items."
            }
        }
        #endif
        return nil
    }()
}

@MainActor
struct ComposerDraft {
    let text: String
    let attachments: [ChatAttachment]
    private let editor: Binding<String>
    private let files: Binding<[ChatAttachment]>

    init(text: Binding<String>, files: Binding<[ChatAttachment]>) {
        editor = text
        self.files = files
        self.text = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        attachments = files.wrappedValue
    }

    var hasContent: Bool { !text.isEmpty || !attachments.isEmpty }

    func clear() {
        if editor.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) == text { editor.wrappedValue = "" }
        let sent = Set(attachments.map(\.id))
        files.wrappedValue.removeAll { sent.contains($0.id) }
    }
}
