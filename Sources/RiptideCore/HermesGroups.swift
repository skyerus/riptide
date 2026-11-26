import Foundation

public struct HermesGroupBot: Decodable, Identifiable, Sendable {
    public let name: String
    public let displayName: String?

    public var id: String { name }
    public var label: String { displayName.flatMap { $0.isEmpty ? nil : $0 } ?? (name == "default" ? "Hermes" : name) }
    public var handle: String { name == "default" ? "hermes" : name }
}

public struct HermesGroup: Decodable, Identifiable, Sendable {
    public struct Member: Decodable, Identifiable, Sendable {
        public let memberId: String
        public let profile: String
        public let handle: String
        public let displayName: String?

        public var id: String { memberId }
        public var label: String { displayName.flatMap { $0.isEmpty ? nil : $0 } ?? handle }
    }

    public let roomId: String
    public let name: String
    public let members: [Member]
    public let authorityGatewayId: String?
    public let authorityEpoch: Int?
    public let latestSeq: Int?
    public var id: String { roomId }
}

public struct HermesGroupCapabilities: Decodable, Sendable {
    public let driver: Bool
    public let methods: [String]?
    public let seatableProfiles: [String]?
    public let maxLogLimit: Int?

    public func offers(_ method: String) -> Bool { methods?.contains("groups.\(method)") ?? true }
}

public struct HermesGroupState: Decodable, Sendable {
    public struct Driver: Decodable, Sendable {
        public struct Activity: Decodable, Identifiable, Sendable {
            public let memberId: String
            public let status: String
            public let tool: String?
            public var id: String { memberId }
        }

        public let running: Bool?
        public let working: Bool
        public let pendingActions: [HermesGroupAction]?
        public let memberActivity: [Activity]?
        public let maxContinues: Int?
    }

    public let room: HermesGroup
    public let driverStatus: Driver?
}

public struct HermesGroupAction: Decodable, Identifiable, Sendable {
    public struct Approval: Decodable, Sendable {
        public let command: String?
        public let description: String?
        public let choices: [String]?
    }

    public let kind: String
    public let memberId: String
    public let taskId: String
    public let executionGeneration: Int
    public let requestId: String?
    public let approval: Approval?
    public var id: String { "\(kind):\(taskId):\(executionGeneration):\(requestId ?? "")" }
}

public struct HermesGroupEvent: Decodable, Identifiable, Sendable {
    public struct Actor: Decodable, Sendable {
        public let kind: String
        public let id: String
        public let displayName: String?
    }

    public struct Payload: Decodable, Sendable {
        public let text: String?
        public let content: String?
        public let threadId: String?
        public let memberId: String?
        public let discussionEventId: String?
        public let status: String?
        public let reason: String?
        public let error: String?
    }

    public let seq: Int
    public let eventId: String
    public let kind: String
    public let actor: Actor
    public let payload: Payload
    public let createdAt: TimeInterval
    public var id: Int { seq }
    public var isMessage: Bool { ["message", "message.user", "message.member"].contains(kind) }
    public var text: String? { payload.text ?? payload.content }
    public var isOwnMessage: Bool {
        actor.kind == "user" && actor.id == "desktop" && (actor.displayName?.isEmpty ?? true)
    }
}

public struct HermesGroupLog: Decodable, Sendable {
    public struct Authority: Decodable, Sendable {
        public let epoch: Int
    }

    public let events: [HermesGroupEvent]
    public let hasMore: Bool
    public let authority: Authority?
}

public struct HermesGroupSend: Codable, Sendable {
    public let id: String
    public let text: String
    public let thread: String

    public init(text: String, thread: String? = nil) {
        id = UUID().uuidString.lowercased()
        self.text = text
        self.thread = thread ?? id
    }
}

public enum HermesGroupError: LocalizedError, Sendable {
    case disconnected
    case invalidReply
    case unsupported
    case rejected(String, admittedNothing: Bool)

    public var errorDescription: String? {
        switch self {
        case .disconnected: "Couldn’t reach the Hermes group chat gateway. Check the connection and try again."
        case .invalidReply: "Hermes returned an incomplete group chat response. Try refreshing."
        case .unsupported: "Group chats aren’t enabled on this Hermes pairing."
        case .rejected(let message, _): message
        }
    }

    public var admittedNothing: Bool {
        if case .rejected(_, let value) = self { return value }
        return false
    }
}

public struct HermesGroupsClient: Sendable {
    private let exchange: @Sendable (Data) async throws -> Data

    public init(exchange: @escaping @Sendable (Data) async throws -> Data) {
        self.exchange = exchange
    }

    init(transport: @escaping @Sendable () -> SSHACPTransport?) {
        let channel = HermesGroupsChannel(makeTransport: transport)
        self.init { try await channel.request($0) }
    }

    private func request<Result: Decodable>(_ method: String, _ params: JSON = [:]) async throws -> Result {
        let id = JSON.string(UUID().uuidString)
        let frame = try JSONEncoder().encode(JSON.request(method, id: id, params: params))
        let reply = try await exchange(frame)
        let decoded = try JSONDecoder().decode(JSON.self, from: reply)
        // An older forced command cannot echo a request ID for a route it doesn't have.
        if decoded["error"]?["code"]?.integer == -32601, decoded["id"] == nil || decoded["id"] == id {
            throw HermesGroupError.unsupported
        }
        guard decoded["id"] == id else { throw HermesGroupError.invalidReply }
        if let error = decoded["error"] {
            let message = error["data"]?["detail"]?.string ?? error["message"]?.string ?? "Hermes couldn’t complete this action."
            throw HermesGroupError.rejected(String(message.prefix(500)), admittedNothing: error["data"]?["admitted"] == .boolean(false))
        }
        guard let result = decoded["result"], result.isObject else { throw HermesGroupError.invalidReply }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Result.self, from: JSONEncoder().encode(result))
        } catch {
            throw HermesGroupError.invalidReply
        }
    }

    public func capabilities() async throws -> HermesGroupCapabilities {
        try await request("groups.capabilities")
    }

    public func bots(capabilities: HermesGroupCapabilities) async throws -> [HermesGroupBot] {
        struct Roster: Decodable { let profiles: [HermesGroupBot] }
        let roster: Roster = try await request("profiles.list", ["include_sessions": .boolean(false)])
        let allowed = capabilities.seatableProfiles.map(Set.init)
        return roster.profiles.filter {
            allowed?.contains($0.name) != false && !["all", "everyone", "user"].contains($0.handle.lowercased())
        }
    }

    public func groups() async throws -> [HermesGroup] {
        struct Page: Decodable { let rooms: [HermesGroup]; let nextOffset: Int? }
        var rooms: [HermesGroup] = []
        var seen = Set<String>()
        var offset = 0
        while true {
            let page: Page = try await request("groups.list", ["limit": .integer(50), "offset": .integer(offset)])
            rooms += page.rooms.filter { seen.insert($0.id).inserted }
            guard let next = page.nextOffset else { return rooms }
            guard next > offset else { throw HermesGroupError.invalidReply }
            offset = next
        }
    }

    public func create(id: String, name: String, bots: [HermesGroupBot]) async throws -> HermesGroup {
        struct Result: Decodable { let room: HermesGroup }
        let members: [JSON] = bots.map {
            var member: [String: JSON] = ["member_id": .string($0.id), "profile": .string($0.id), "handle": .string($0.handle)]
            if let display = $0.displayName, !display.isEmpty { member["display_name"] = .string(display) }
            return .object(member)
        }
        let result: Result = try await request("groups.create", ["room_id": .string(id), "name": .string(name), "members": .array(members)])
        guard result.room.id == id else { throw HermesGroupError.invalidReply }
        return result.room
    }

    public func state(room id: String) async throws -> HermesGroupState {
        let result: HermesGroupState = try await request("groups.state", ["room_id": .string(id)])
        guard result.room.id == id else { throw HermesGroupError.invalidReply }
        return result
    }

    public func log(room id: String, after seq: Int, limit: Int) async throws -> HermesGroupLog {
        try await request("groups.log", ["room_id": .string(id), "since_seq": .integer(seq), "limit": .integer(limit)])
    }

    public func send(_ message: HermesGroupSend, room id: String) async throws {
        struct Receipt: Decodable { let clientEventId: String; let accepted: Bool? }
        let receipt: Receipt = try await request("groups.send", ["room_id": .string(id), "event_id": .string(message.id),
            "payload": ["text": .string(message.text), "thread_id": .string(message.thread)]])
        guard receipt.clientEventId == message.id, receipt.accepted != false else { throw HermesGroupError.invalidReply }
    }

    public func stop(room id: String, cancelID: String) async throws {
        try await control("stop", ["room_id": .string(id), "cancel_id": .string(cancelID)])
    }

    public func resume(room id: String, discussionID: String) async throws {
        try await control("continue", ["room_id": .string(id), "discussion_event_id": .string(discussionID)])
    }

    public func rename(room id: String, name: String) async throws {
        try await control("rename", ["room_id": .string(id), "name": .string(name), "event_id": .string(UUID().uuidString)])
    }

    public func disband(room id: String, cancelID: String) async throws {
        struct Result: Decodable {
            struct Tombstone: Decodable { let roomId: String; let disbandedAt: TimeInterval? }
            let tombstone: Tombstone
        }
        let result: Result = try await request("groups.disband", ["room_id": .string(id), "cancel_id": .string(cancelID)])
        guard result.tombstone.roomId == id, result.tombstone.disbandedAt != nil else { throw HermesGroupError.invalidReply }
    }

    public func act(_ action: HermesGroupAction, choice: String? = nil, room id: String) async throws {
        var params: [String: JSON] = ["room_id": .string(id), "member_id": .string(action.memberId),
            "task_id": .string(action.taskId), "execution_generation": .integer(action.executionGeneration)]
        guard action.executionGeneration > 0 else { throw HermesGroupError.invalidReply }
        if action.kind == "retry" {
            try await control("retry", params)
            return
        }
        guard action.kind == "approval", let requestID = action.requestId, !requestID.isEmpty,
              let choice, ["once", "deny"].contains(choice), action.approval?.choices?.contains(choice) == true,
              choice != "once" || action.approval?.command?.isEmpty == false else {
            throw HermesGroupError.invalidReply
        }
        params["request_id"] = .string(requestID)
        params["choice"] = .string(choice)
        try await control("approve", params)
    }

    private func control(_ method: String, _ params: [String: JSON]) async throws {
        let _: JSON = try await request("groups.\(method)", .object(params))
    }
}

private actor HermesGroupsChannel {
    private struct Link {
        let transport: SSHACPTransport
        var reader: AsyncThrowingStream<Data, any Error>.Iterator
        var lastUse = ContinuousClock.now
    }

    let makeTransport: @Sendable () -> SSHACPTransport?
    private var link: Link?
    private var previous: Task<Void, Never>?

    init(makeTransport: @escaping @Sendable () -> SSHACPTransport?) {
        self.makeTransport = makeTransport
    }

    func request(_ frame: Data) async throws -> Data {
        let prior = previous
        let work = Task {
            await prior?.value
            try Task.checkCancellation()
            return try await exchange(frame)
        }
        previous = Task { _ = try? await work.value }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private func exchange(_ frame: Data) async throws -> Data {
        var current: Link
        if let link, link.lastUse.duration(to: .now) < .seconds(35) {
            current = link
        } else {
            if let link { await link.transport.close() }
            guard let transport = makeTransport() else { throw HermesGroupError.disconnected }
            current = Link(transport: transport, reader: transport.incoming.makeAsyncIterator())
        }
        link = nil
        let transport = current.transport
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(32)) } catch { return }
            await transport.close()
        }
        defer { deadline.cancel() }
        do {
            try await transport.send(frame)
            guard let reply = try await current.reader.next(isolation: self) else { throw HermesGroupError.disconnected }
            current.lastUse = .now
            link = current
            return reply
        } catch {
            await transport.close()
            try Task.checkCancellation()
            throw HermesGroupError.disconnected
        }
    }
}
