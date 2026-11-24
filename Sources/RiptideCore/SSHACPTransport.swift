import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

public struct SSHDeviceIdentity: Sendable {
    let key: NIOSSHPrivateKey
    public let privateCredential: String

    public init() {
        let privateKey = Curve25519.Signing.PrivateKey()
        key = NIOSSHPrivateKey(ed25519Key: privateKey)
        privateCredential = privateKey.rawRepresentation.base64EncodedString()
    }

    init?(privateCredential: String) {
        guard let bytes = Data(base64Encoded: privateCredential),
              let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes) else { return nil }
        key = NIOSSHPrivateKey(ed25519Key: privateKey)
        self.privateCredential = privateCredential
    }

    public var publicKey: String { String(openSSHPublicKey: key.publicKey) }
}

enum SSHACPError: LocalizedError {
    case hostKeyMismatch, credentialsRejected, channelRejected, invalidFrame

    var errorDescription: String? {
        switch self {
        case .hostKeyMismatch: "The SSH host key doesn’t match the pinned fingerprint."
        case .credentialsRejected: "The SSH server didn’t accept this device key."
        case .channelRejected: "The SSH server didn’t start the ACP command."
        case .invalidFrame: "The SSH server returned an invalid or oversized ACP frame."
        }
    }
}

struct SSHHostPin: Sendable {
    let fingerprint: String

    init?(_ input: String) {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.hasPrefix("SHA256:"),
              let bytes = Data(base64Encoded: String(input.dropFirst(7)) + "="), bytes.count == 32,
              Self.format(bytes) == input else { return nil }
        fingerprint = input
    }

    func matches(_ key: NIOSSHPublicKey) -> Bool {
        guard let payload = String(openSSHPublicKey: key).split(separator: " ").dropFirst().first,
              let bytes = Data(base64Encoded: String(payload)) else { return false }
        return Self.format(Data(SHA256.hash(data: bytes))) == fingerprint
    }

    private static func format(_ bytes: Data) -> String {
        "SHA256:" + bytes.base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

final class SSHACPTransport: ACPTransport {
    let incoming: AsyncThrowingStream<Data, any Error>
    private let startup: Task<(parent: any Channel, session: any Channel), any Error>

    init(host: String, port: Int, username: String, identity: SSHDeviceIdentity, pin: SSHHostPin) {
        let (stream, output) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        incoming = stream
        startup = Task {
            do {
                let parent = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .connectTimeout(.seconds(10))
                    .channelInitializer { channel in
                        channel.eventLoop.makeCompletedFuture {
                            let handler = NIOSSHHandler(
                                role: .client(.init(
                                    userAuthDelegate: DeviceAuthentication(username: username, identity: identity),
                                    serverAuthDelegate: PinnedServerAuthentication(pin: pin)
                                )),
                                allocator: channel.allocator, inboundChildChannelInitializer: nil
                            )
                            try channel.pipeline.syncOperations.addHandler(handler)
                            try channel.pipeline.syncOperations.addHandler(SSHConnectionErrors(output: output))
                        }
                    }
                    .connect(host: host, port: port).get()
                let deadline = parent.eventLoop.scheduleTask(in: .seconds(12)) { parent.close(promise: nil) }
                defer { deadline.cancel() }
                do {
                    try Task.checkCancellation()
                    let accepted = parent.eventLoop.makePromise(of: Void.self)
                    let session = try await parent.eventLoop.flatSubmit { () -> EventLoopFuture<any Channel> in
                        let handler: NIOSSHHandler
                        do { handler = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self) }
                        catch { return parent.eventLoop.makeFailedFuture(error) }
                        let opened = parent.eventLoop.makePromise(of: (any Channel).self)
                        handler.createChannel(opened) { channel, type in
                            guard type == .session else {
                                return channel.eventLoop.makeFailedFuture(SSHACPError.channelRejected)
                            }
                            return channel.eventLoop.makeCompletedFuture {
                                try channel.pipeline.syncOperations.addHandler(ACPExecChannel(accepted: accepted, output: output))
                            }
                        }
                        return opened.futureResult
                    }.get()
                    session.closeFuture.whenComplete { _ in parent.close(promise: nil) }
                    try await accepted.futureResult.get()
                    return (parent, session)
                } catch {
                    parent.close(promise: nil)
                    throw error
                }
            } catch {
                output.finish(throwing: error)
                throw error
            }
        }
    }

    deinit {
        let startup = startup
        startup.cancel()
        Task {
            if let channels = try? await startup.value {
                channels.parent.close(promise: nil)
            }
        }
    }

    func send(_ message: Data) async throws {
        guard !message.contains(10), message.count <= ACPExecChannel.maximumFrameBytes else {
            throw SSHACPError.invalidFrame
        }
        let (_, session) = try await startup.value
        var buffer = session.allocator.buffer(capacity: message.count + 1)
        buffer.writeBytes(message)
        buffer.writeInteger(UInt8(10))
        try await session.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).get()
    }
}

private final class DeviceAuthentication: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let identity: SSHDeviceIdentity
    var attempted = false

    init(username: String, identity: SSHDeviceIdentity) {
        self.username = username
        self.identity = identity
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !attempted, availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHACPError.credentialsRejected)
            return
        }
        attempted = true
        nextChallengePromise.succeed(.init(username: username, serviceName: "ssh-connection",
                                           offer: .privateKey(.init(privateKey: identity.key))))
    }
}

private struct PinnedServerAuthentication: NIOSSHClientServerAuthenticationDelegate {
    let pin: SSHHostPin

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if pin.matches(hostKey) { validationCompletePromise.succeed(()) }
        else { validationCompletePromise.fail(SSHACPError.hostKeyMismatch) }
    }
}

private final class SSHConnectionErrors: ChannelInboundHandler {
    typealias InboundIn = Never
    let output: AsyncThrowingStream<Data, any Error>.Continuation

    init(output: AsyncThrowingStream<Data, any Error>.Continuation) { self.output = output }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        output.finish(throwing: error)
        context.close(promise: nil)
    }
}

private final class ACPExecChannel: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    static let maximumFrameBytes = 2 * 1024 * 1024
    private var accepted: EventLoopPromise<Void>?
    private let output: AsyncThrowingStream<Data, any Error>.Continuation
    private var partialFrame = ByteBuffer()

    init(accepted: EventLoopPromise<Void>, output: AsyncThrowingStream<Data, any Error>.Continuation) {
        self.accepted = accepted
        self.output = output
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: "riptide-acp", wantReply: true),
                                         promise: nil)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            accepted?.succeed(())
            accepted = nil
        case is ChannelFailureEvent:
            errorCaught(context: context, error: SSHACPError.channelRejected)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let packet = unwrapInboundIn(data)
        guard packet.type == .channel, case .byteBuffer(let bytes) = packet.data else { return }
        let chunks = bytes.readableBytesView.split(separator: 10, omittingEmptySubsequences: false)
        for (index, chunk) in chunks.enumerated() {
            guard partialFrame.readableBytes + chunk.count <= Self.maximumFrameBytes else {
                errorCaught(context: context, error: SSHACPError.invalidFrame)
                return
            }
            partialFrame.writeBytes(chunk)
            guard index < chunks.count - 1 else { return }
            guard partialFrame.readableBytes > 0 else { continue }
            let result = output.yield(Data(partialFrame.readableBytesView))
            partialFrame.clear()
            if case .dropped = result {
                errorCaught(context: context, error: SSHACPError.invalidFrame)
                return
            }
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        accepted?.fail(SSHACPError.channelRejected)
        accepted = nil
        output.finish()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        accepted?.fail(error)
        accepted = nil
        output.finish(throwing: error)
        context.close(promise: nil)
    }
}
