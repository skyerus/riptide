import AVFoundation
import RiptideCore
import SwiftUI

typealias DictationTranscriber = @Sendable (Data) async throws -> String

struct DictatingComposer<Field: View, Options: View, Actions: View>: View {
    let focused: Bool
    let showsOptions: Bool
    let chatID: String?
    let canDictate: Bool
    @Binding var draft: String
    let transcribe: DictationTranscriber?
    let dismissKeyboard: () -> Void
    @ViewBuilder let field: () -> Field
    @ViewBuilder let options: () -> Options
    @ViewBuilder let actions: () -> Actions

    @Environment(\.scenePhase) private var scenePhase
    @State private var dictation = ComposerDictation()

    var body: some View {
        ComposerSurface(focused: focused && !dictation.active, showsOptions: showsOptions && !dictation.active) {
            if dictation.active {
                recordingDisplay
            } else {
                field()
            }
        } options: {
            options()
        } actions: {
            if dictation.active {
                control("Cancel dictation", symbol: "xmark", identifier: "dictation-cancel", action: dictation.cancel)
                if dictation.recording, let transcribe {
                    ComposerAction("Finish dictating", symbol: "checkmark", disabled: false) {
                        dictation.finish(transcribe: transcribe, insert: insert)
                    }
                    .accessibilityIdentifier("dictation-finish")
                }
            } else {
                if transcribe != nil {
                    control("Dictate", symbol: "mic", identifier: "dictation-start", disabled: !canDictate) {
                        dismissKeyboard()
                        dictation.start()
                    }
                }
                actions()
            }
        }
        .task(id: dictation.recording) {
            guard dictation.recording, let transcribe else { return }
            while !Task.isCancelled, dictation.recording {
                if dictation.sample() {
                    dictation.finish(transcribe: transcribe, insert: insert)
                    break
                }
                do { try await Task.sleep(for: .milliseconds(90)) } catch { break }
            }
        }
        .onChange(of: chatID) { reset() }
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
            if dictation.recording {
                Circle()
                    .fill(Color.red)
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
                .font(.system(size: 16, weight: .medium))
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

    private func reset() {
        dictation.cancel()
        dictation.error = nil
    }
}

@MainActor
@Observable
private final class ComposerDictation {
    private enum Phase { case idle, preparing, recording, transcribing }
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
    var activeLabel: String {
        switch phase {
        case .idle: ""
        case .preparing: "Starting microphone…"
        case .recording: "Recording dictation"
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
        return elapsed >= .seconds(CodexDictation.maximumDuration) || recorder?.isRecording == false
    }

    func finish(transcribe: @escaping DictationTranscriber, insert: @escaping (String) -> Void) {
        guard recording else { return }
        let url = recordingURL
        stopMicrophone()
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
    static var transcribe: DictationTranscriber? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["RIPTIDE_DICTATION_FIXTURE"] == "1" {
            return { _ in
                try await Task.sleep(for: .milliseconds(500))
                return "Add a quick summary of the open items."
            }
        }
        #endif
        return nil
    }
}
