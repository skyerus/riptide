import CryptoKit
import Darwin
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
    private let startup: Task<(parent: any Channel, session: any Channel, frames: SSHFrameReader), any Error>

    init(host: String, port: Int, username: String, identity: SSHDeviceIdentity, pin: SSHHostPin,
         command: String = "riptide-acp") {
        let startup = Task<(parent: any Channel, session: any Channel, frames: SSHFrameReader), any Error> {
            let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
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
                        try channel.pipeline.syncOperations.addHandler(SSHConnectionErrors())
                    }
                }
            if command == "riptide-acp" {
                // Kernel keepalives can preserve the SSH socket while app code is suspended.
                _ = bootstrap
                    .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
                    .channelOption(ChannelOptions.tcpOption(.init(rawValue: TCP_KEEPALIVE)), value: 60)
            }
            let parent = try await bootstrap.connect(host: host, port: port).get()
            let deadline = parent.eventLoop.scheduleTask(in: .seconds(12)) { parent.close(promise: nil) }
            defer { deadline.cancel() }
            do {
                try Task.checkCancellation()
                let accepted = parent.eventLoop.makePromise(of: Void.self)
                let framedChannel = parent.eventLoop.makePromise(of: NIOAsyncChannel<Data, Never>.self)
                let session = try await parent.eventLoop.flatSubmit { () -> EventLoopFuture<any Channel> in
                    let handler: NIOSSHHandler
                    do { handler = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self) }
                    catch { return parent.eventLoop.makeFailedFuture(error) }
                    let opened = parent.eventLoop.makePromise(of: (any Channel).self)
                    opened.futureResult.whenFailure { error in
                        accepted.fail(error)
                        framedChannel.fail(error)
                    }
                    handler.createChannel(opened) { channel, type in
                        guard type == .session else {
                            return channel.eventLoop.makeFailedFuture(SSHACPError.channelRejected)
                        }
                        return channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(ACPExecChannel(
                                accepted: accepted, command: command
                            ))
                            let framed = try NIOAsyncChannel<Data, Never>(wrappingChannelSynchronously: channel)
                            framedChannel.succeed(framed)
                        }
                    }
                    return opened.futureResult
                }.get()
                session.closeFuture.whenComplete { _ in parent.close(promise: nil) }
                try await accepted.futureResult.get()
                let framed = try await framedChannel.futureResult.get()
                let frames = await withCheckedContinuation { continuation in
                    Task {
                        try? await framed.executeThenClose { inbound, _ in
                            continuation.resume(returning: SSHFrameReader(inbound))
                            try await session.closeFuture.get()
                        }
                    }
                }
                return (parent, session, frames)
            } catch {
                parent.close(promise: nil)
                throw error
            }
        }
        self.startup = startup
        // Pull frames on demand so the SSH channel can pause reads while the ACP consumer catches up.
        incoming = AsyncThrowingStream(unfolding: {
            try await startup.value.frames.next()
        })
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

    func close() async {
        startup.cancel()
        if let channels = try? await startup.value { channels.parent.close(promise: nil) }
    }

    func send(_ message: Data) async throws {
        guard !message.contains(10), message.count <= ACPExecChannel.maximumFrameBytes else {
            throw SSHACPError.invalidFrame
        }
        let session = try await startup.value.session
        var buffer = session.allocator.buffer(capacity: message.count + 1)
        buffer.writeBytes(message)
        buffer.writeInteger(UInt8(10))
        try await session.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).get()
    }
}

private actor SSHFrameReader {
    private var iterator: NIOAsyncChannelInboundStream<Data>.AsyncIterator

    init(_ stream: NIOAsyncChannelInboundStream<Data>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> Data? {
        var iterator = self.iterator
        let frame = try await iterator.next(isolation: self)
        self.iterator = iterator
        return frame
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

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}

private final class ACPExecChannel: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Data
    static let maximumFrameBytes = 2 * 1024 * 1024
    private var accepted: EventLoopPromise<Void>?
    private let command: String
    private var partialFrame = ByteBuffer()

    init(accepted: EventLoopPromise<Void>, command: String) {
        self.accepted = accepted
        self.command = command
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true),
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
            let frame = Data(partialFrame.readableBytesView)
            partialFrame.clear()
            context.fireChannelRead(wrapInboundOut(frame))
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        accepted?.fail(SSHACPError.channelRejected)
        accepted = nil
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        accepted?.fail(error)
        accepted = nil
        context.fireErrorCaught(error)
        context.close(promise: nil)
    }
}
