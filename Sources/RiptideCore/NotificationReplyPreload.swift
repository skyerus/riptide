import CryptoKit
import Foundation

public struct NotificationReplyLocator: Codable, Equatable, Sendable {
    public let workspace: UUID
    public let chat: String
    public let eventID: String

    public init?(workspace: String, chat: String, eventID: String) {
        guard let workspace = UUID(uuidString: workspace),
              chat.wholeMatch(of: /[A-Za-z0-9._:-]{1,240}/) != nil,
              eventID.wholeMatch(of: /[A-Za-z0-9._:-]{1,160}/) != nil else { return nil }
        self.workspace = workspace
        self.chat = chat
        self.eventID = eventID
    }
}

/// A device-local store shared by the app and its notification service extension.
public struct NotificationReplyStore: Sendable {
    public static let appGroup = "group.app.riptide.client"

    struct Route: Codable, Equatable, Sendable {
        let profile: RemoteProfile
        let credential: String
    }

    private struct Reply: Codable {
        let locator: NotificationReplyLocator
        let text: String
    }

    private let root: URL
    private let sizeLimit = 2 * 1024 * 1024
    private let replyLimit = 8
    private let lifetime: TimeInterval = 24 * 60 * 60

    public init(root: URL) { self.root = root }

    public static var shared: Self? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup).map {
            Self(root: $0.appending(path: "Library/Caches/NotificationReplies-v1"))
        }
    }

    /// This key has its own server-enforced reply-only SSH command.
    public func prepareRoute(for profile: RemoteProfile) throws -> String {
        guard profile.kind == .hermes, profile.sshHostFingerprint != nil else { throw URLError(.unsupportedURL) }
        let existing = route(for: profile.id)
        let identity = existing.flatMap { SSHDeviceIdentity(privateCredential: $0.credential) } ?? SSHDeviceIdentity()
        let route = Route(profile: profile, credential: identity.privateCredential)
        if existing != route {
            let folder = directory(profile.id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(route).write(to: routeURL(profile.id),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        return identity.publicKey
    }

    func route(for workspace: UUID) -> Route? {
        guard let data = try? Data(contentsOf: routeURL(workspace)), data.count <= 16_384,
              let route = try? JSONDecoder().decode(Route.self, from: data),
              route.profile.id == workspace else { return nil }
        return route
    }

    public func removeWorkspace(_ workspace: UUID) {
        try? FileManager.default.removeItem(at: directory(workspace))
    }

    public func read(_ locator: NotificationReplyLocator) -> String? {
        guard route(for: locator.workspace) != nil else { return nil }
        let file = replyURL(locator)
        guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let written = values.contentModificationDate, Date().timeIntervalSince(written) <= lifetime,
              let size = values.fileSize, size <= sizeLimit,
              let data = try? Data(contentsOf: file),
              let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.locator == locator else { return nil }
        return reply.text
    }

    public func download(_ locator: NotificationReplyLocator) async throws {
        guard let route = route(for: locator.workspace) else { return }
        let text = try await route.profile.notificationReply(locator, credential: route.credential)
        try Task.checkCancellation()
        guard self.route(for: locator.workspace)?.credential == route.credential else { return }
        try save(text, for: locator)
    }

    func save(_ text: String, for locator: NotificationReplyLocator) throws {
        let data = try JSONEncoder().encode(Reply(locator: locator, text: text))
        guard data.count <= sizeLimit, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let file = replyURL(locator)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let key: Set<URLResourceKey> = [.contentModificationDateKey]
        let entries = try FileManager.default.contentsOfDirectory(at: directory(locator.workspace),
                                                                    includingPropertiesForKeys: Array(key))
        let others = entries.filter { $0 != file && $0.pathExtension == "reply" }.sorted {
            ((try? $0.resourceValues(forKeys: key).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: key).contentModificationDate) ?? .distantPast)
        }
        for old in others.dropFirst(replyLimit - 1) { try? FileManager.default.removeItem(at: old) }
    }

    private func directory(_ workspace: UUID) -> URL { root.appending(path: workspace.uuidString) }
    private func routeURL(_ workspace: UUID) -> URL { directory(workspace).appending(path: "route.json") }

    private func replyURL(_ locator: NotificationReplyLocator) -> URL {
        let key = SHA256.hash(data: Data("\(locator.chat)\n\(locator.eventID)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory(locator.workspace).appending(path: key + ".reply")
    }
}
