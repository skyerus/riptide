import AVFAudio
import Foundation
@preconcurrency import WebRTC

@MainActor
final class CodexVoiceMedia: NSObject {
    enum State: Sendable {
        case connected, interrupted, failed
    }

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let audio = RTCAudioSessionConfiguration.webRTC()
        audio.categoryOptions.insert(.defaultToSpeaker)
        RTCAudioSessionConfiguration.setWebRTC(audio)
        return RTCPeerConnectionFactory()
    }()

    private var peer: RTCPeerConnection?
    private var microphone: RTCAudioTrack?
    private var channel: RTCDataChannel?
    private var audioDisabled = false
    private let onState: @MainActor (State) -> Void
    private let onData: (@MainActor (Data) -> Void)?

    init(onState: @escaping @MainActor (State) -> Void, onData: (@MainActor (Data) -> Void)? = nil) {
        self.onState = onState
        self.onData = onData
    }

    func offer(listenOnly: Bool, dataChannel: Bool = true) async throws -> String {
        if listenOnly {
            let session = RTCAudioSession.sharedInstance()
            session.useManualAudio = true
            session.isAudioEnabled = false
            audioDisabled = true
        }
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = Self.factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw VoiceMediaError.setup
        }
        self.peer = peer
        let audio = RTCRtpTransceiverInit()
        audio.direction = listenOnly ? .recvOnly : .sendRecv
        if listenOnly {
            guard peer.addTransceiver(of: .audio, init: audio) != nil else { throw VoiceMediaError.setup }
        } else {
            let track = Self.factory.audioTrack(withTrackId: "riptide-voice")
            track.isEnabled = false
            guard peer.addTransceiver(with: track, init: audio) != nil else { throw VoiceMediaError.setup }
            microphone = track
        }
        if dataChannel {
            channel = peer.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration())
            guard channel != nil else { throw VoiceMediaError.setup }
            if onData != nil { channel?.delegate = self }
        }
        let offer = try await peer.offer(for: constraints)
        try await peer.setLocalDescription(offer)
        for _ in 0..<50 {
            try Task.checkCancellation()
            if peer.iceGatheringState == .complete, let sdp = peer.localDescription?.sdp { return sdp }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw VoiceMediaError.network
    }

    func accept(_ answer: String) async throws {
        guard let peer, peer.remoteDescription == nil else { throw VoiceMediaError.setup }
        try await peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer))
    }

    func setMuted(_ muted: Bool) { microphone?.isEnabled = !muted }

    func send(_ data: Data) {
        guard let channel, channel.readyState == .open, channel.bufferedAmount < 128 * 1024 else { return }
        _ = channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    func close() {
        setMuted(true)
        channel?.close()
        peer?.close()
        channel = nil
        peer = nil
        microphone = nil
        if audioDisabled {
            RTCAudioSession.sharedInstance().useManualAudio = false
            audioDisabled = false
        }
    }

}

extension CodexVoiceMedia: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        guard dataChannel.readyState == .closed else { return }
        Task { @MainActor [weak self] in self?.onState(.interrupted) }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let payload = buffer.data
        guard !buffer.isBinary, payload.count <= 64 * 1024 else { return }
        Task { @MainActor [weak self] in self?.onData?(payload) }
    }
}

extension CodexVoiceMedia: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        let state: State
        switch newState {
        case .connected: state = .connected
        case .disconnected: state = .interrupted
        case .failed, .closed: state = .failed
        default: return
        }
        Task { @MainActor [weak self] in self?.onState(state) }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

enum VoiceMediaError: LocalizedError {
    case setup, network, microphoneDenied

    var errorDescription: String? {
        switch self {
        case .setup: "The phone couldn’t start voice audio."
        case .network: "The voice connection couldn’t reach Codex."
        case .microphoneDenied: "Allow microphone access in Settings to make a voice call."
        }
    }
}
