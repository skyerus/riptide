import AVFAudio
import CallKit
import Foundation
import RiptideCore

@MainActor
protocol SystemVoiceCall: AnyObject {
    var id: UUID { get }
    var name: String { get }
    var connectedAt: Date? { get }
    var finished: Bool { get }
    func startMedia(systemAudio: Bool) throws
    func finish(_ message: String?)
    func setMuted(_ muted: Bool)
    func setHeld(_ held: Bool)
    func setSystemAudioActive(_ active: Bool)
}

@MainActor
final class NativeCallSystem: NSObject, @preconcurrency CXProviderDelegate {
    static let shared = NativeCallSystem()

    private let controller = CXCallController()
    private let provider: CXProvider
    private var current: (any SystemVoiceCall)?
    private var activeAudioSession: AVAudioSession?

    private override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportedHandleTypes = [.generic]
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.includesCallsInRecents = false
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    func start(_ call: any SystemVoiceCall) async throws {
        guard current == nil else { throw VoiceMediaError.callInProgress }
        current = call
        let action = CXStartCallAction(call: call.id, handle: CXHandle(type: .generic, value: call.name))
        do {
            try await controller.request(CXTransaction(action: action))
        } catch {
            if current === call { current = nil }
            throw error
        }
    }

    func connected(_ call: any SystemVoiceCall) {
        guard current === call else { return }
        provider.reportOutgoingCall(with: call.id, connectedAt: call.connectedAt)
    }

    func requestMute(_ isMuted: Bool, for call: any SystemVoiceCall) async throws {
        guard current === call else { return }
        try await controller.request(CXTransaction(action: CXSetMutedCallAction(call: call.id, muted: isMuted)))
    }

    func requestEnd(_ call: any SystemVoiceCall) async throws {
        guard current === call else { return }
        try await controller.request(CXTransaction(action: CXEndCallAction(call: call.id)))
    }

    func ended(_ call: any SystemVoiceCall, reason: CXCallEndedReason) {
        guard current === call else { return }
        current = nil
        provider.reportCall(with: call.id, endedAt: Date(), reason: reason)
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard let call = current, call.id == action.callUUID, !call.finished else { action.fail(); return }
        do {
            try call.startMedia(systemAudio: true)
            if activeAudioSession != nil { call.setSystemAudioActive(true) }
            let update = CXCallUpdate()
            update.localizedCallerName = call.name
            update.remoteHandle = action.handle
            update.supportsHolding = true
            update.supportsGrouping = false
            update.supportsUngrouping = false
            update.supportsDTMF = false
            provider.reportCall(with: call.id, updated: update)
            provider.reportOutgoingCall(with: call.id, startedConnectingAt: Date())
            action.fulfill()
        } catch {
            current = nil
            action.fail()
            call.finish(error.localizedDescription)
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard let call = current, call.id == action.callUUID else { action.fail(); return }
        current = nil
        call.finish(nil)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard let call = current, call.id == action.callUUID else { action.fail(); return }
        call.setMuted(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        guard let call = current, call.id == action.callUUID else { action.fail(); return }
        call.setHeld(action.isOnHold)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        guard activeAudioSession == nil else { return }
        activeAudioSession = audioSession
        CodexVoiceMedia.systemAudioActivated(audioSession)
        current?.setSystemAudioActive(true)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        deactivateAudio()
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        guard let action = action as? CXCallAction, let call = current, call.id == action.callUUID else { return }
        if action is CXStartCallAction || action is CXEndCallAction {
            call.finish(VoiceMediaError.network.localizedDescription)
        }
    }

    func providerDidReset(_ provider: CXProvider) {
        let call = current
        deactivateAudio()
        current = nil
        call?.finish("The system ended the call.")
    }

    private func deactivateAudio() {
        guard let audioSession = activeAudioSession else { return }
        activeAudioSession = nil
        current?.setSystemAudioActive(false)
        CodexVoiceMedia.systemAudioDeactivated(audioSession)
    }
}
