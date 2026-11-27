import Foundation

public protocol JSONMessageTransport: Sendable {
    var incoming: AsyncThrowingStream<Data, any Error> { get }
    func send(_ message: Data) async throws
    func close() async
}

public extension JSONMessageTransport {
    func close() async {}
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

public enum ChatRole: String, Codable, Sendable {
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
    case assistantProgress(sessionID: String, messageID: String, text: String)
    case agentActivity(sessionID: String)
    case turnActivity(sessionID: String, working: Bool, steerAdmissionID: String?)
    case replyTimedOut(sessionID: String)
    case contextCompaction(sessionID: String, ContextCompaction)
    case tool(sessionID: String, activity: ToolActivity)
    case plan(sessionID: String, steps: [TurnPlanStep])
    case configOptions(sessionID: String, options: [SessionConfigOption])
    case context(sessionID: String, usage: ContextUsage)
    case permission(PermissionRequest)
    case permissionClosed(sessionID: String, id: UUID)

    var sessionID: String {
        switch self {
        case .message(let sessionID, _, _, _), .assistantProgress(let sessionID, _, _),
             .tool(let sessionID, _), .configOptions(let sessionID, _),
             .context(let sessionID, _), .permissionClosed(let sessionID, _), .plan(let sessionID, _),
             .agentActivity(let sessionID), .turnActivity(let sessionID, _, _), .replyTimedOut(let sessionID),
             .contextCompaction(let sessionID, _):
            sessionID
        case .permission(let request):
            request.sessionID
        }
    }
}

public enum ACPError: LocalizedError, Equatable {
    case disconnected, malformedResponse, protocolVersion, historyUnavailable, sessionListUnavailable
    case permissionExpired
    case methodUnavailable(String)
    case invalidParameters(String)
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .disconnected: "The agent connection closed."
        case .malformedResponse: "The agent returned an incomplete response."
        case .protocolVersion: "This agent did not negotiate ACP v1."
        case .historyUnavailable: "This agent cannot reopen saved conversations over ACP."
        case .sessionListUnavailable: "This agent cannot list saved conversations over ACP."
        case .permissionExpired: "This approval is no longer active."
        case .methodUnavailable(let message): message
        case .invalidParameters(let message): message
        case .rejected(let message): message
        }
    }
}

public actor ACPClient {
    public nonisolated let events: AsyncStream<ACPEvent>
    private let emit: AsyncStream<ACPEvent>.Continuation
    private let transport: any ACPTransport
    private let restrictedSSH: Bool
    private let onDisplayName: (@MainActor @Sendable (String) -> Void)?
    private var reader: Task<Void, Never>?
    private var initialization: Task<JSON, any Error>?
    private var nextID = 0
    private var pending: [JSON: CheckedContinuation<JSON, any Error>] = [:]
    private var replaying: [String: [ACPEvent]] = [:]
    private var resumingHistory: [String: [JSON]] = [:]
    private var permissions: [UUID: (wireID: JSON, request: PermissionRequest)] = [:]
    private var activePrompts = Set<String>()
    private var voiceReplies: [String: String] = [:]
    private var cancelledPrompts = Set<String>()
    private var disconnected = false
    private var loadedSessions = Set<String>()
    private var newVoiceSessionKeys: [String: String]?

    public init(transport: any ACPTransport, restrictedSSH: Bool = false,
                onDisplayName: (@MainActor @Sendable (String) -> Void)? = nil) {
        self.transport = transport
        self.restrictedSSH = restrictedSSH
        self.onDisplayName = onDisplayName
        (events, emit) = AsyncStream.makeStream()
    }

    deinit { reader?.cancel(); emit.finish() }

    public func canLoadSessions() async throws -> Bool {
        try await initialize()["loadSession"] == .boolean(true)
    }

    public func close() async {
        reader?.cancel()
        disconnect()
        await transport.close()
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
        let capabilities = try await initialize()
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
                             reportedModelName: SessionConfigOption.reportedModelName(in: response),
                             acceptsImages: acceptsImages(capabilities))
    }

    public func load(sessionID: String, cwd: String) async throws -> OpenedSession {
        try await load(sessionID: sessionID, cwd: cwd, cachedHistory: nil, fastResume: false)
    }

    func load(sessionID: String, cwd: String, cachedHistory: ChatHistorySnapshot?, fastResume: Bool) async throws -> OpenedSession {
        let capabilities = try await initialize()
        if fastResume, capabilities["_meta"]?["app.riptide.fastResume"] == .integer(1) {
            do {
                return try await resume(sessionID: sessionID, cwd: cwd, cache: cachedHistory, capabilities: capabilities)
            } catch ACPError.methodUnavailable {
                // The installed SSH wrapper may predate the negotiated adapter.
            } catch ACPError.invalidParameters {
                // Some saved sessions still require the connector's legacy load path.
            }
        }
        guard capabilities["loadSession"] == .boolean(true) else { throw ACPError.historyUnavailable }
        replaying[sessionID] = []
        defer { replaying.removeValue(forKey: sessionID) }
        let response = try await call("session/load", [
            "sessionId": .string(sessionID), "cwd": .string(cwd), "mcpServers": .array([])
        ])
        loadedSessions.insert(sessionID)
        return OpenedSession(id: sessionID, configOptions: response["configOptions"]?.array.map(SessionConfigOption.parse),
                             events: replaying[sessionID] ?? [],
                             reportedModelName: SessionConfigOption.reportedModelName(in: response),
                             acceptsImages: acceptsImages(capabilities))
    }

    func recentHistory(sessionID: String, cwd: String) async throws -> [ACPEvent] {
        let capabilities = try await initialize()
        guard capabilities["_meta"]?["app.riptide.fastResume"] == .integer(1) else { return [] }
        let response = try await call("_riptide/session/recent", ["sessionId": .string(sessionID), "cwd": .string(cwd)])
        return Self.historyEvents(response["updates"]?.array ?? [], sessionID: sessionID)
    }

    private func resume(sessionID: String, cwd: String, cache: ChatHistorySnapshot?, capabilities: JSON) async throws -> OpenedSession {
        resumingHistory[sessionID] = []
        defer { resumingHistory.removeValue(forKey: sessionID) }
        var params: [String: JSON] = ["sessionId": .string(sessionID), "cwd": .string(cwd), "mcpServers": .array([])]
        params["checkpoint"] = cache?.checkpoint.wire
        let response = try await call("_riptide/session/resume", .object(params))
        guard let checkpoint = ChatHistoryCheckpoint(wire: response["checkpoint"]),
              case .boolean(let useCache)? = response["reuseHistory"], !useCache || cache != nil else {
            throw ACPError.malformedResponse
        }
        let updates = (useCache ? cache?.updates ?? [] : []) + (resumingHistory[sessionID] ?? [])
        loadedSessions.insert(sessionID)
        return OpenedSession(id: sessionID, configOptions: response["configOptions"]?.array.map(SessionConfigOption.parse),
                             events: Self.historyEvents(updates, sessionID: sessionID),
                             reportedModelName: SessionConfigOption.reportedModelName(in: response),
                             acceptsImages: acceptsImages(capabilities),
                             historySnapshot: ChatHistorySnapshot(checkpoint: checkpoint, updates: updates))
    }

    static func historyEvents(_ updates: [JSON], sessionID: String) -> [ACPEvent] {
        updates.compactMap { event($0, sessionID: sessionID, replaying: true) }
    }

    public func setConfigOption(sessionID: String, configID: String, value: String) async throws -> [SessionConfigOption] {
        _ = try await initialize()
        let result = try await call("session/set_config_option", [
            "sessionId": .string(sessionID), "configId": .string(configID), "value": .string(value)
        ])
        guard let options = result["configOptions"]?.array else { throw ACPError.malformedResponse }
        return SessionConfigOption.parse(options)
    }

    public func prompt(_ text: String, sessionID: String, attachments: [ChatAttachment] = []) async throws -> String {
        try await runPrompt(text, sessionID: sessionID, collectReply: false, attachments: attachments).reason
    }

    func promptWithDelivery(_ text: String, sessionID: String, attachments: [ChatAttachment], photoID: UUID?,
                            onWritten: @escaping @Sendable () async -> Void) async throws -> (reason: String, timedOut: Bool) {
        let result = try await runPrompt(text, sessionID: sessionID, collectReply: false, attachments: attachments,
                                         photoID: photoID, onWritten: onWritten)
        return (result.reason, result.timedOut)
    }

    public func promptForVoice(_ text: String, sessionID: String) async throws -> String {
        let result = try await runPrompt(text, sessionID: sessionID, collectReply: true)
        guard result.reason == "end_turn", !result.timedOut else { return "" }
        return result.reply
    }

    enum SteerOutcome: Equatable, Sendable { case accepted, idle, notDelivered }

    /// False means the host confirmed that it did not accept the follow-up.
    public func steer(_ text: String, sessionID: String, observedAdmissionID: String? = nil) async throws -> Bool {
        try await steerOutcome(text, sessionID: sessionID, observedAdmissionID: observedAdmissionID) == .accepted
    }

    func steerOutcome(_ text: String, sessionID: String, observedAdmissionID: String?) async throws -> SteerOutcome {
        guard loadedSessions.contains(sessionID), observedAdmissionID != nil || activePrompts.contains(sessionID) else { return .idle }
        var params: [String: JSON] = ["sessionId": .string(sessionID), "text": .string(text)]
        params["admissionId"] = observedAdmissionID.map(JSON.string)
        let result: JSON
        do {
            result = try await call("_riptide/session/steer", .object(params))
        } catch ACPError.methodUnavailable {
            throw ACPError.rejected("This host can’t steer an active reply. Hold Send to queue the message instead.")
        }
        switch result["status"]?.string {
        case "steered": return .accepted
        case "idle": return result["delivered"] == .boolean(false) ? .notDelivered : .idle
        default: throw ACPError.malformedResponse
        }
    }

    private func runPrompt(_ text: String, sessionID: String, collectReply: Bool,
                           attachments: [ChatAttachment] = [], photoID: UUID? = nil,
                           onWritten: (@Sendable () async -> Void)? = nil) async throws -> (reason: String, reply: String, timedOut: Bool) {
        let capabilities = try await initialize()
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
        let blocks = try await promptBlocks(text, attachments: attachments, capabilities: capabilities, photoID: photoID)
        if cancelledPrompts.contains(sessionID) { return ("cancelled", "", false) }
        let response = try await call("session/prompt", [
            "sessionId": .string(sessionID), "prompt": .array(blocks)
        ], onWritten: onWritten)
        guard let reason = response["stopReason"]?.string else { throw ACPError.malformedResponse }
        let timedOut = response["_meta"]?["app.riptide.turnFailure"]?.string == "timeout"
        return (reason, voiceReplies[sessionID] ?? "", timedOut)
    }

    private func acceptsImages(_ capabilities: JSON) -> Bool {
        capabilities["promptCapabilities"]?["image"] == .boolean(true)
            && (!restrictedSSH || stagesFiles(capabilities))
    }

    private func stagesFiles(_ capabilities: JSON) -> Bool {
        capabilities["_meta"]?["riptide.app/attachments"] == .integer(1)
    }

    // Some ACP runtimes only replay text. Carry an opaque reference to this device’s photo copy
    // in a text block so that replay can recover it without matching on the user's wording.
    static let photoReferencePrefix = "[Riptide photo reference: "
    static let photoReferenceSuffix = "]"

    private func promptBlocks(_ text: String, attachments: [ChatAttachment], capabilities: JSON,
                              photoID: UUID?) async throws -> [JSON] {
        var blocks: [JSON] = text.isEmpty ? [] : [["type": "text", "text": .string(text)]]
        guard !attachments.isEmpty else { return blocks }
        guard attachments.count <= ChatAttachment.maxCount,
              attachments.reduce(0, { $0 + $1.data.count }) <= ChatAttachment.acpByteLimit else {
            throw ACPError.rejected("A message can include up to four attachments and 1 MB total on this connection.")
        }

        let vision = acceptsImages(capabilities)
        let files = attachments.filter { $0.imageMIMEType == nil || !vision }
        if !files.isEmpty {
            if stagesFiles(capabilities) {
                let uploads: [JSON] = files.map { [
                    "name": .string($0.hostFilename), "dataBase64": .string($0.data.base64EncodedString())
                ] }
                let reply = try await call("riptide/stageAttachments", ["files": .array(uploads)])
                guard let paths = reply["paths"]?.array?.compactMap(\.string), paths.count == files.count,
                      paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains(where: \.isNewline) }) else {
                    throw ACPError.malformedResponse
                }
                for (file, path) in zip(files, paths) {
                    blocks.append(["type": "text", "text": .string(file.reference(to: path))])
                }
            } else {
                for file in files {
                    guard let contents = file.inlineText else {
                        throw ACPError.rejected("This agent connection can only attach small UTF-8 text files. Update the Riptide host bridge for other files.")
                    }
                    blocks.append(["type": "text", "text": .string("Attached text file: \(file.name)\n\(contents)")])
                }
            }
        }
        if let photoID {
            blocks.append(["type": "text", "text": .string(Self.photoReferencePrefix + photoID.uuidString + Self.photoReferenceSuffix)])
        }
        if vision {
            for image in attachments {
                guard let mime = image.imageMIMEType else { continue }
                blocks.append(["type": "text", "text": .string("Attached image: \(image.name)")])
                blocks.append(["type": "image", "mimeType": .string(mime), "data": .string(image.data.base64EncodedString())])
            }
        }
        return blocks
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
            var params: [String: JSON] = [
                "protocolVersion": .integer(1),
                "clientCapabilities": ["_meta": ["app.riptide.assistantProgress": .boolean(true)]],
                "clientInfo": ["name": "riptide", "version": "0.1.0"]
            ]
            let reply: JSON
            do {
                reply = try await call("initialize", .object(params))
            } catch ACPError.invalidParameters where restrictedSSH {
                // Older forced commands only admit an empty capabilities object.
                params["clientCapabilities"] = [:]
                reply = try await call("initialize", .object(params))
            }
            guard reply["protocolVersion"] == .integer(1) else { throw ACPError.protocolVersion }
            return reply["agentCapabilities"] ?? [:]
        }
        initialization = handshake
        return try await handshake.value
    }

    private func call(_ method: String, _ params: JSON,
                      onWritten: (@Sendable () async -> Void)? = nil) async throws -> JSON {
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
                    do {
                        try await send(.request(method, id: id, params: params))
                        await onWritten?()
                    } catch { fail(id, error: error) }
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
                    guard activePrompts.contains(sessionID) || loadedSessions.contains(sessionID)
                            || replaying[sessionID] != nil || resumingHistory[sessionID] != nil,
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
            } else if method == "_riptide/session/history", let sessionID = params["sessionId"]?.string,
                      let update = params["update"] {
                resumingHistory[sessionID]?.append(update)
            } else if method == "_riptide/agent/profile", initialization != nil,
                      let proposed = params["name"]?.string, let name = RemoteProfile.validDisplayName(proposed) {
                await onDisplayName?(name)
            } else if method == "session/update", let sessionID = params["sessionId"]?.string, let update = params["update"] {
                if update["sessionUpdate"] == "session_info_update", let key = update["_meta"]?["sessionKey"]?.string,
                   let count = newVoiceSessionKeys?.count, count < 24, key.utf8.count <= 512 {
                    newVoiceSessionKeys?[sessionID] = key
                }
                guard let event = Self.event(update, sessionID: sessionID, replaying: replaying[sessionID] != nil) else { return }
                if case .message(_, _, .assistant, let text) = event, let soFar = voiceReplies[sessionID] {
                    voiceReplies[sessionID] = String((soFar + text).suffix(4_800))
                }
                if replaying[sessionID] != nil {
                    replaying[sessionID]?.append(event)
                } else {
                    if case .replyTimedOut = event { closePermissions(in: sessionID) }
                    emit.yield(event)
                }
            }
        } else if let id = message["id"], let request = pending.removeValue(forKey: id) {
            if let error = message["error"]?["message"]?.string {
                switch message["error"]?["code"]?.integer {
                case -32601: request.resume(throwing: ACPError.methodUnavailable(error))
                case -32602: request.resume(throwing: ACPError.invalidParameters(error))
                default: request.resume(throwing: ACPError.rejected(error))
                }
            }
            else if let result = message["result"] { request.resume(returning: result) }
            else { request.resume(throwing: ACPError.malformedResponse) }
        }
    }

    private static func event(_ update: JSON, sessionID: String, replaying: Bool) -> ACPEvent? {
        switch update["sessionUpdate"]?.string {
        case "session_info_update":
            let metadata = update["_meta"]
            if metadata?["app.riptide.turnFailure"]?.string == "timeout" { return .replyTimedOut(sessionID: sessionID) }
            if let item = metadata?["app.riptide.contextCompaction"],
               case .boolean(let running)? = item["running"],
               let compaction = ContextCompaction(item, running: running) {
                return .contextCompaction(sessionID: sessionID, compaction)
            }
            guard case .boolean(let working)? = metadata?["app.riptide.turnWorking"] else { return nil }
            let admissionID = metadata?["app.riptide.steerAdmissionId"]?.string
                .flatMap { !$0.isEmpty && $0.utf8.count <= 256 ? $0 : nil }
            return .turnActivity(sessionID: sessionID, working: working, steerAdmissionID: working ? admissionID : nil)
        case "agent_thought_chunk":
            guard update["content"]?["type"] == "text", let text = update["content"]?["text"]?.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .agentActivity(sessionID: sessionID)
        case "plan":
            guard let steps = update["entries"]?.array else { return nil }
            return .plan(sessionID: sessionID, steps: steps.prefix(24).compactMap { TurnPlanStep($0) })
        case "agent_message_chunk", "user_message_chunk":
            guard update["content"]?["type"] == "text", let text = update["content"]?["text"]?.string else { return nil }
            let role: ChatRole = update["sessionUpdate"] == "agent_message_chunk" ? .assistant : .user
            let messageID = update["messageId"]?.string
            if replaying, role == .assistant, messageID == nil, let compaction = ContextCompaction(legacyRecord: text) {
                return .contextCompaction(sessionID: sessionID, compaction)
            }
            if role == .assistant, let messageID, update["_meta"]?["app.riptide.assistantProgress"] == .boolean(true) {
                return .assistantProgress(sessionID: sessionID, messageID: messageID, text: text)
            }
            return .message(sessionID: sessionID, messageID: messageID, role: role, text: text)
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
