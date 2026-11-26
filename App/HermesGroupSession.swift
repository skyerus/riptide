import CryptoKit
import Foundation
import Observation
import RiptideCore

@MainActor @Observable
final class HermesGroupSession {
    let client: HermesGroupsClient
    let roomID: String
    private let pendingFile: URL
    private(set) var snapshot: HermesGroupState?
    private(set) var capabilities: HermesGroupCapabilities?
    private(set) var events: [HermesGroupEvent] = []
    private(set) var pending: HermesGroupSend?
    private(set) var sending = false
    private(set) var acting = false
    private(set) var readError: String?
    private(set) var actionError: String?
    private var reading = false
    private var sendMayHavePosted = false
    private var cancelID: String?
    private var disbandID: String?
    private var journalUnreadable = false
    var draft = ""
    var reply: HermesGroupEvent?

    init(client: HermesGroupsClient, roomID: String, workspaceID: String) {
        self.client = client
        self.roomID = roomID
        pendingFile = Self.draftDirectory(workspaceID).appending(path: Self.digest(roomID))
        restorePending()
    }

    static func removeDrafts(workspaceID: String) {
        try? FileManager.default.removeItem(at: draftDirectory(workspaceID))
    }

    private static func draftDirectory(_ workspaceID: String) -> URL {
        URL.applicationSupportDirectory.appending(path: "HermesGroupSends", directoryHint: .isDirectory)
            .appending(path: digest(workspaceID), directoryHint: .isDirectory)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func restorePending() {
        do {
            let saved = try JSONDecoder().decode(HermesGroupSend.self, from: Data(contentsOf: pendingFile))
            pending = saved
            draft = saved.text
            sendMayHavePosted = true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A first visit has no unresolved send.
        } catch {
            journalUnreadable = true
            actionError = "Riptide couldn’t restore the pending message. Try refreshing."
            return
        }
        if journalUnreadable { actionError = nil }
        journalUnreadable = false
    }

    var members: [HermesGroup.Member] { snapshot?.room.members ?? [] }
    var driver: HermesGroupState.Driver? { snapshot?.driverStatus }
    var canSend: Bool {
        driver != nil && driver?.running != false && offers("send") && !sending && !acting && !journalUnreadable &&
        (pending != nil || (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.utf8.count <= 64 * 1024))
    }

    func offers(_ method: String) -> Bool { capabilities?.offers(method) == true }

    func label(for id: String) -> String { members.first { $0.id == id }?.label ?? id }

    func author(of event: HermesGroupEvent) -> String {
        if event.isOwnMessage { return "You" }
        return event.actor.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? label(for: event.actor.id)
    }

    func refresh() async {
        guard !reading else { return }
        reading = true
        defer { reading = false }
        if journalUnreadable { restorePending() }
        do {
            if capabilities == nil { capabilities = try await client.capabilities() }
            let state = try await client.state(room: roomID)
            var cursor = events.last?.seq ?? 0
            let reset = state.room.authorityEpoch != snapshot?.room.authorityEpoch || (state.room.latestSeq ?? cursor) < cursor
            if reset { cursor = 0 }
            var added: [HermesGroupEvent] = []
            if state.room.latestSeq != cursor {
                let limit = min(capabilities?.maxLogLimit ?? 40, 40)
                repeat {
                    try Task.checkCancellation()
                    let page = try await client.log(room: roomID, after: cursor, limit: limit)
                    if let epoch = state.room.authorityEpoch, let logEpoch = page.authority?.epoch, epoch != logEpoch {
                        throw HermesGroupError.invalidReply
                    }
                    let fresh = page.events.filter { $0.seq > cursor }
                    for event in fresh {
                        guard event.seq == cursor + 1 else { throw HermesGroupError.invalidReply }
                        cursor = event.seq
                    }
                    added += fresh
                    if !page.hasMore { break }
                    guard !fresh.isEmpty else { throw HermesGroupError.invalidReply }
                } while true
            }
            guard cursor >= (state.room.latestSeq ?? cursor) else { throw HermesGroupError.invalidReply }
            try Task.checkCancellation()
            snapshot = state
            if reset { events = added }
            else if !added.isEmpty { events += added }
            readError = nil
            if !sending, let pending,
               events.contains(where: { $0.eventId == "user:" + Self.digest(pending.id) }) {
                finishSend()
            }
        } catch {
            guard !Task.isCancelled else { return }
            readError = error.localizedDescription
            capabilities = nil
        }
    }

    func send() async {
        guard canSend else { return }
        let message = pending ?? HermesGroupSend(text: draft.trimmingCharacters(in: .whitespacesAndNewlines),
                                                thread: reply?.payload.threadId)
        do {
            if pending == nil {
                try FileManager.default.createDirectory(at: pendingFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(message).write(to: pendingFile, options: [.atomic, .completeFileProtection])
                pending = message
            }
        } catch {
            actionError = "Riptide couldn’t save this message for a safe retry."
            return
        }
        sending = true
        actionError = nil
        defer { sending = false }
        do {
            try await client.send(message, room: roomID)
            finishSend()
        } catch {
            if (error as? HermesGroupError)?.admittedNothing == true, !sendMayHavePosted {
                if removePending() { actionError = error.localizedDescription }
            } else {
                sendMayHavePosted = true
                actionError = "Delivery hasn’t been confirmed. Retry to send the same message safely."
            }
        }
        await refresh()
    }

    func stop() async {
        guard !acting, !sending else { return }
        let token = cancelID ?? UUID().uuidString
        cancelID = token
        await perform {
            try await client.stop(room: roomID, cancelID: token)
            cancelID = nil
        }
    }

    func rename(_ name: String) async {
        await perform { try await client.rename(room: roomID, name: name) }
    }

    func disband() async -> Bool {
        guard !acting, !sending else { return false }
        let token = disbandID ?? UUID().uuidString
        disbandID = token
        acting = true
        defer { acting = false }
        do {
            try await client.disband(room: roomID, cancelID: token)
            removePending()
            return true
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }

    func resume(_ discussion: String) async {
        await perform { try await client.resume(room: roomID, discussionID: discussion) }
    }

    func act(_ action: HermesGroupAction, choice: String? = nil) async {
        await perform { try await client.act(action, choice: choice, room: roomID) }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !acting, !sending else { return }
        acting = true
        defer { acting = false }
        actionError = nil
        do { try await operation() }
        catch { actionError = error.localizedDescription }
        await refresh()
    }

    private func finishSend() {
        guard removePending() else { return }
        draft = ""
        reply = nil
        actionError = nil
    }

    @discardableResult
    private func removePending() -> Bool {
        do { try FileManager.default.removeItem(at: pendingFile) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
        catch {
            actionError = "Riptide couldn’t clear the saved message. Refresh to check delivery."
            return false
        }
        pending = nil
        sendMayHavePosted = false
        return true
    }
}
