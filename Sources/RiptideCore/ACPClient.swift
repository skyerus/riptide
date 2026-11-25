import Foundation

public protocol JSONMessageTransport: Sendable {
    var incoming: AsyncThrowingStream<Data, any Error> { get }
    func send(_ message: Data) async throws
}

public typealias ACPTransport = JSONMessageTransport

public struct SessionSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let cwd: String?
    public let nativeSessionKey: String?

    init(id: String, title: String, cwd: String?, nativeSessionKey: String? = nil) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.nativeSessionKey = nativeSessionKey
    }
}

public enum ChatRole: String, Sendable {
    case user, assistant
}

public struct ToolActivity: Sendable, Equatable {
    public let id: String
    public let title: String?
    public let status: String?
}

public struct PermissionRequest: Identifiable, Sendable, Equatable {
    public struct Option: Identifiable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let kind: String
    }

    public let id: UUID
    public let sessionID: String
    public let title: String
    public let options: [Option]
    public let toolCallID: String?
}

public enum ACPEvent: Sendable, Equatable {
    case message(sessionID: String, messageID: String?, role: ChatRole, text: String)
    case tool(sessionID: String, activity: ToolActivity)
    case plan(sessionID: String, steps: [TurnPlanStep])
    case configOptions(sessionID: String, options: [SessionConfigOption])
    case context(sessionID: String, usage: ContextUsage)
    case permission(PermissionRequest)
    case permissionClosed(sessionID: String, id: UUID)

    var sessionID: String {
        switch self {
        case .message(let sessionID, _, _, _), .tool(let sessionID, _), .configOptions(let sessionID, _),
             .context(let sessionID, _), .permissionClosed(let sessionID, _), .plan(let sessionID, _):
            sessionID
        case .permission(let request):
            request.sessionID
        }
    }
}

public enum ACPError: LocalizedError, Equatable {
    case disconnected, malformedResponse, protocolVersion, historyUnavailable, sessionListUnavailable
    case permissionExpired
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .disconnected: "The agent connection closed."
        case .malformedResponse: "The agent returned an incomplete response."
        case .protocolVersion: "This agent did not negotiate ACP v1."
        case .historyUnavailable: "This agent cannot reopen saved conversations over ACP."
        case .sessionListUnavailable: "This agent cannot list saved conversations over ACP."
        case .permissionExpired: "This approval is no longer active."
        case .rejected(let message): message
        }
    }
}

public actor ACPClient {
    public nonisolated let events: AsyncStream<ACPEvent>
    private let emit: AsyncStream<ACPEvent>.Continuation
    private let transport: any ACPTransport
    private var reader: Task<Void, Never>?
    private var initialization: Task<JSON, any Error>?
    private var nextID = 0
    private var pending: [JSON: CheckedContinuation<JSON, any Error>] = [:]
    private var replaying: [String: [ACPEvent]] = [:]
    private var permissions: [UUID: (wireID: JSON, request: PermissionRequest)] = [:]
    private var activePrompts = Set<String>()
    private var voiceReplies: [String: String] = [:]
    private var cancelledPrompts = Set<String>()
    private var disconnected = false
    private var loadedSessions = Set<String>()
    private var newVoiceSessionKeys: [String: String]?

    public init(transport: any ACPTransport) {
        self.transport = transport
        (events, emit) = AsyncStream.makeStream()
    }

    deinit { reader?.cancel(); emit.finish() }

    public func canLoadSessions() async throws -> Bool {
        try await initialize()["loadSession"] == .boolean(true)
    }

    public func close() {
        reader?.cancel()
        disconnect()
    }

    public func sessions(maximumPages: Int? = nil) async throws -> [SessionSummary] {
        let capabilities = try await initialize()
        guard case .object? = capabilities["sessionCapabilities"]?["list"] else {
            throw ACPError.sessionListUnavailable
        }
        var sessions: [SessionSummary] = []
        var cursor: String?
        var seenCursors = Set<String>()
        var pages = 0
        var seenSessions = Set<String>()
        repeat {
            try Task.checkCancellation()
            let params: JSON = cursor.map { ["cursor": .string($0)] } ?? [:]
            let response = try await call("session/list", params)
            guard let entries = response["sessions"]?.array else { throw ACPError.malformedResponse }
            for entry in entries {
                guard let id = entry["sessionId"]?.string else { throw ACPError.malformedResponse }
                if seenSessions.insert(id).inserted {
                    sessions.append(SessionSummary(
                        id: id, title: entry["title"]?.string ?? "Untitled chat", cwd: entry["cwd"]?.string,
                        nativeSessionKey: entry["_meta"]?["sessionKey"]?.string
                    ))
                }
            }
            cursor = response["nextCursor"]?.string
            if let cursor, !seenCursors.insert(cursor).inserted { throw ACPError.malformedResponse }
            pages += 1
        } while cursor != nil && pages < (maximumPages ?? .max)
        return sessions
    }

    public func newSession(cwd: String, nativeSessionKey: String? = nil) async throws -> OpenedSession {
        _ = try await initialize()
        guard newVoiceSessionKeys == nil else { throw ACPError.rejected("Another chat is opening.") }
        var params: [String: JSON] = ["cwd": .string(cwd), "mcpServers": .array([])]
        if let nativeSessionKey {
            params["_meta"] = ["sessionKey": .string(nativeSessionKey)]
            newVoiceSessionKeys = [:]
        }
        defer { if nativeSessionKey != nil { newVoiceSessionKeys = nil } }
        let response = try await call("session/new", .object(params))
        guard let id = response["sessionId"]?.string else { throw ACPError.malformedResponse }
        let echoedKey = response["_meta"]?["sessionKey"]?.string ?? newVoiceSessionKeys?[id]
        if let nativeSessionKey, echoedKey != nativeSessionKey {
            throw ACPError.rejected("The OpenClaw host didn’t confirm a separate chat.")
        }
        loadedSessions.insert(id)
        return OpenedSession(id: id, configOptions: response["configOptions"]?.array.map(SessionConfigOption.parse),
                             events: [], nativeSessionKey: nativeSessionKey,
                             reportedModelName: SessionConfigOption.reportedModelName(in: response))
    }

    public func load(sessionID: String, cwd: String) async throws -> OpenedSession {
        let capabilities = try await initialize()
        guard capabilities["loadSession"] == .boolean(true) else { throw ACPError.historyUnavailable }
        replaying[sessionID] = []
        defer { replaying.removeValue(forKey: sessionID) }
        let response = try await call("session/load", [
            "sessionId": .string(sessionID), "cwd": .string(cwd), "mcpServers": .array([])
        ])
        loadedSessions.insert(sessionID)
        return OpenedSession(id: sessionID, configOptions: response["configOptions"]?.array.map(SessionConfigOption.parse),
                             events: replaying[sessionID] ?? [],
                             reportedModelName: SessionConfigOption.reportedModelName(in: response))
    }

    public func setConfigOption(sessionID: String, configID: String, value: String) async throws -> [SessionConfigOption] {
        _ = try await initialize()
        let result = try await call("session/set_config_option", [
            "sessionId": .string(sessionID), "configId": .string(configID), "value": .string(value)
        ])
        guard let options = result["configOptions"]?.array else { throw ACPError.malformedResponse }
        return SessionConfigOption.parse(options)
    }

    public func prompt(_ text: String, sessionID: String) async throws -> String {
        try await runPrompt(text, sessionID: sessionID, collectReply: false).reason
    }

    public func promptForVoice(_ text: String, sessionID: String) async throws -> String {
        let result = try await runPrompt(text, sessionID: sessionID, collectReply: true)
        guard result.reason == "end_turn" else { return "" }
        return result.reply
    }

    private func runPrompt(_ text: String, sessionID: String, collectReply: Bool) async throws -> (reason: String, reply: String) {
        _ = try await initialize()
        guard activePrompts.insert(sessionID).inserted else {
            throw ACPError.rejected("This conversation is already working.")
        }
        defer {
            activePrompts.remove(sessionID)
            voiceReplies.removeValue(forKey: sessionID)
            cancelledPrompts.remove(sessionID)
            closePermissions(in: sessionID)
        }
        if collectReply { voiceReplies[sessionID] = "" }
        let response = try await call("session/prompt", [
            "sessionId": .string(sessionID), "prompt": .array([["type": "text", "text": .string(text)]])
        ])
        guard let reason = response["stopReason"]?.string else { throw ACPError.malformedResponse }
        return (reason, voiceReplies[sessionID] ?? "")
    }

    public func cancel(sessionID: String) async throws {
        guard !disconnected else { throw ACPError.disconnected }
        guard activePrompts.contains(sessionID) else { return }
        cancelledPrompts.insert(sessionID)
        do { try await send(.notification("session/cancel", params: ["sessionId": .string(sessionID)])) }
        catch { cancelledPrompts.remove(sessionID); throw error }
        for id in permissions.values.filter({ $0.request.sessionID == sessionID }).map(\.request.id) {
            try? await resolve(id, optionID: nil)
        }
    }

    public func resolve(_ permissionID: UUID, optionID: String?) async throws {
        guard !disconnected, let pending = permissions[permissionID] else { throw ACPError.permissionExpired }
        let outcome: JSON
        if let optionID {
            guard !cancelledPrompts.contains(pending.request.sessionID),
                  let option = pending.request.options.first(where: { $0.id == optionID }),
                  ["allow_once", "reject_once"].contains(option.kind) else { throw ACPError.permissionExpired }
            outcome = ["outcome": "selected", "optionId": .string(optionID)]
        } else {
            outcome = ["outcome": "cancelled"]
        }
        closePermission(permissionID, sessionID: pending.request.sessionID)
        try await send(.reply(pending.wireID, result: ["outcome": outcome]))
    }

    private func initialize() async throws -> JSON {
        guard !disconnected else { throw ACPError.disconnected }
        if let initialization { return try await initialization.value }
        reader = Task { [weak self, transport] in
            do {
                for try await data in transport.incoming {
                    guard !Task.isCancelled else { return }
                    await self?.receive(data)
                }
            } catch {}
            await self?.disconnect()
        }
        let handshake = Task {
            let reply = try await call("initialize", [
                "protocolVersion": .integer(1), "clientCapabilities": [:],
                "clientInfo": ["name": "riptide", "version": "0.1.0"]
            ])
            guard reply["protocolVersion"] == .integer(1) else { throw ACPError.protocolVersion }
            return reply["agentCapabilities"] ?? [:]
        }
        initialization = handshake
        return try await handshake.value
    }

    private func call(_ method: String, _ params: JSON) async throws -> JSON {
        try Task.checkCancellation()
        guard !disconnected else { throw ACPError.disconnected }
        nextID += 1
        let id = JSON.integer(nextID)
        let timeout: Task<Void, Never>? = method == "session/prompt" ? nil : Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            await self?.fail(id, error: ACPError.rejected("The agent did not respond in time."))
        }
        defer { timeout?.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                Task {
                    guard pending[id] != nil else { return }
                    do { try await send(.request(method, id: id, params: params)) }
                    catch { fail(id, error: error) }
                }
            }
        } onCancel: {
            Task { await self.fail(id, error: CancellationError()) }
        }
    }

    private func send(_ message: JSON) async throws {
        try await transport.send(JSONEncoder().encode(message))
    }

    private func receive(_ data: Data) async {
        guard let message = try? JSONDecoder().decode(JSON.self, from: data),
              message["jsonrpc"] == "2.0" else { return }
        if let method = message["method"]?.string {
            let params = message["params"] ?? [:]
            if let id = message["id"], id.rpcID {
                if method == "session/request_permission", let sessionID = params["sessionId"]?.string,
                   let tool = params["toolCall"], let options = params["options"]?.array {
                    guard activePrompts.contains(sessionID) || loadedSessions.contains(sessionID) || replaying[sessionID] != nil,
                          !cancelledPrompts.contains(sessionID) else {
                        try? await send(.reply(id, result: ["outcome": ["outcome": "cancelled"]]))
                        return
                    }
                    let request = PermissionRequest(
                        id: UUID(), sessionID: sessionID, title: tool["title"]?.string ?? "Tool action",
                        options: options.compactMap { option in
                            guard let id = option["optionId"]?.string, let name = option["name"]?.string,
                                  let kind = option["kind"]?.string else { return nil }
                            return PermissionRequest.Option(id: id, name: name, kind: kind)
                        }, toolCallID: tool["toolCallId"]?.string
                    )
                    permissions[request.id] = (id, request)
                    emit.yield(.permission(request))
                } else {
                    try? await send(.failure(id, code: -32601, message: "Unsupported client request"))
                }
            } else if method == "session/update", let sessionID = params["sessionId"]?.string, let update = params["update"] {
                if update["sessionUpdate"] == "session_info_update", let key = update["_meta"]?["sessionKey"]?.string,
                   let count = newVoiceSessionKeys?.count, count < 24, key.utf8.count <= 512 {
                    newVoiceSessionKeys?[sessionID] = key
                }
                guard let event = Self.event(update, sessionID: sessionID) else { return }
                if case .message(_, _, .assistant, let text) = event, let soFar = voiceReplies[sessionID] {
                    voiceReplies[sessionID] = String((soFar + text).suffix(4_800))
                }
                if replaying[sessionID] != nil { replaying[sessionID]?.append(event) }
                else { emit.yield(event) }
            }
        } else if let id = message["id"], let request = pending.removeValue(forKey: id) {
            if let error = message["error"]?["message"]?.string { request.resume(throwing: ACPError.rejected(error)) }
            else if let result = message["result"] { request.resume(returning: result) }
            else { request.resume(throwing: ACPError.malformedResponse) }
        }
    }

    private static func event(_ update: JSON, sessionID: String) -> ACPEvent? {
        switch update["sessionUpdate"]?.string {
        case "plan":
            guard let steps = update["entries"]?.array else { return nil }
            return .plan(sessionID: sessionID, steps: steps.prefix(24).compactMap { TurnPlanStep($0) })
        case "agent_message_chunk", "user_message_chunk":
            guard update["content"]?["type"] == "text", let text = update["content"]?["text"]?.string else { return nil }
            let role: ChatRole = update["sessionUpdate"] == "agent_message_chunk" ? .assistant : .user
            return .message(sessionID: sessionID, messageID: update["messageId"]?.string, role: role, text: text)
        case "tool_call", "tool_call_update":
            guard let id = update["toolCallId"]?.string else { return nil }
            return .tool(sessionID: sessionID, activity: ToolActivity(
                id: id, title: update["title"]?.string, status: update["status"]?.string
            ))
        case "config_option_update":
            guard let options = update["configOptions"]?.array else { return nil }
            return .configOptions(sessionID: sessionID, options: SessionConfigOption.parse(options))
        case "usage_update":
            guard let used = update["used"]?.integer, let size = update["size"]?.integer,
                  let usage = ContextUsage(used: used, capacity: size) else { return nil }
            return .context(sessionID: sessionID, usage: usage)
        default: return nil
        }
    }

    private func fail(_ id: JSON, error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func closePermissions(in sessionID: String) {
        for id in permissions.values.filter({ $0.request.sessionID == sessionID }).map(\.request.id) {
            closePermission(id, sessionID: sessionID)
        }
    }

    private func closePermission(_ id: UUID, sessionID: String) {
        permissions.removeValue(forKey: id)
        emit.yield(.permissionClosed(sessionID: sessionID, id: id))
    }

    private func disconnect() {
        disconnected = true
        let waiting = pending.values
        pending.removeAll()
        for continuation in waiting { continuation.resume(throwing: ACPError.disconnected) }
        for (id, entry) in Array(permissions) { closePermission(id, sessionID: entry.request.sessionID) }
        emit.finish()
    }
}
