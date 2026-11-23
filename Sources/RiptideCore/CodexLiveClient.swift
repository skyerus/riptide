import CryptoKit
import Foundation

public struct CodexLocalEndpoint: Sendable {
    public let workspace: String
    private let url: URL
    private let bearer: String
    private let accountFingerprint: String?

    public init?(remote: RemoteProfile, bearer: String) {
        guard remote.kind == .codex, let url = RemoteProfile.secureURL(remote.address),
              remote.workspace.hasPrefix("/"), RemoteProfile.validBearer(bearer) else { return nil }
        self.url = url
        self.bearer = bearer
        workspace = remote.workspace
        accountFingerprint = remote.accountFingerprint
    }

    public init?(environment: [String: String]) {
        guard let raw = environment["RIPTIDE_CODEX_URL"], let url = URL(string: raw),
              url.scheme == "ws", url.host == "127.0.0.1", url.port != nil,
              url.user == nil, url.password == nil, url.path.isEmpty, url.query == nil, url.fragment == nil,
              let token = environment["RIPTIDE_CODEX_BEARER"], token.count >= 32,
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }),
              let workspace = environment["RIPTIDE_CODEX_WORKSPACE"], workspace.hasPrefix("/") else { return nil }
        self.url = url
        bearer = token
        self.workspace = workspace
        accountFingerprint = nil
    }

    public func makeClient() -> CodexLiveClient {
        let transport = RemoteWebSocketTransport(url: url, bearer: bearer)
        return CodexLiveClient(transport: transport, workspace: workspace, accountFingerprint: accountFingerprint)
    }
}

public struct CodexLiveTurn: Equatable, Sendable {
    public let threadID: String
    public let turnID: String
    public let model: String?
    public let prompt: String?
}

public enum CodexLiveEvent: Equatable, Sendable {
    case output(turnID: String, text: String)
    case assistantDelta(turnID: String, itemID: String, text: String)
    case assistantCompleted(turnID: String, itemID: String, text: String)
    case diff(turnID: String, patch: String)
    case completed(turnID: String, status: String)

    var turnID: String {
        switch self {
        case .output(let turnID, _), .assistantDelta(let turnID, _, _), .diff(let turnID, _),
             .assistantCompleted(let turnID, _, _), .completed(let turnID, _): turnID
        }
    }
}

public enum CodexCallEvent: Equatable, Sendable {
    case answer(String)
}

public enum CodexLiveError: LocalizedError, Equatable {
    case connectionClosed, timedOut, noActiveTurn, multipleActiveThreads, invalidResponse, wrongTurn
    case requiresChatGPTSignIn
    case wrongWorkspace, expiredApproval, notSignedIn, accountChanged, accountUnidentified
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .connectionClosed: "The connection to Codex closed."
        case .timedOut: "Codex did not respond in time."
        case .noActiveTurn: "No running turn in this workspace. Start one in Codex, then try again."
        case .multipleActiveThreads: "More than one chat is active here. Use a workspace with one test chat."
        case .invalidResponse: "Codex returned an incomplete response."
        case .wrongTurn: "Codex did not confirm the same turn."
        case .requiresChatGPTSignIn: "Voice requires a ChatGPT subscription sign-in on the Codex host. API keys aren’t used."
        case .wrongWorkspace: "This chat does not belong to the paired workspace."
        case .expiredApproval: "This request is no longer available on this connection."
        case .notSignedIn: "Sign in to Codex on the host before pairing."
        case .accountChanged: "The host’s Codex account or workspace changed. Pair it again to use that account."
        case .accountUnidentified: "The host did not return a ChatGPT account identity. Use a current, signed-in App Server."
        case .rejected(let reason): reason
        }
    }
}

public actor CodexLiveClient {
    public nonisolated let events: AsyncThrowingStream<CodexLiveEvent, any Error>
    public nonisolated let chatEvents: AsyncThrowingStream<CodexChatEvent, any Error>
    private let emit: AsyncThrowingStream<CodexLiveEvent, any Error>.Continuation
    private var emitVoice: AsyncThrowingStream<CodexCallEvent, any Error>.Continuation?
    private let emitChat: AsyncThrowingStream<CodexChatEvent, any Error>.Continuation
    private let transport: any JSONMessageTransport
    private let workspace: String
    private let accountFingerprint: String?
    private var reader: Task<Void, Never>?
    private var pending: [JSON: CheckedContinuation<JSON, any Error>] = [:]
    private var nextID = 0
    private var closed = false
    private var threadID: String?
    private var activeTurnID: String?
    private var voiceThreadID: String?
    private var voiceAttempt: UUID?
    private var endingVoice = false
    private var joined = false
    private var joiningEvents: [CodexLiveEvent] = []
    private var savedChat = false
    private var verifiedChat = false
    private var turnChanged = false
    private var submitting = false
    private var latestCompletedTurn: String?
    private var approvals: [JSON: CodexChatApproval] = [:]
    private var responsesInFlight = Set<JSON>()

    init(transport: any JSONMessageTransport, workspace: String, accountFingerprint: String? = nil) {
        self.transport = transport
        self.workspace = workspace
        self.accountFingerprint = accountFingerprint
        (events, emit) = AsyncThrowingStream.makeStream()
        (chatEvents, emitChat) = AsyncThrowingStream.makeStream()
    }

    deinit { reader?.cancel(); emit.finish(); emitVoice?.finish(); emitChat.finish() }

    public func listSavedChats() async throws -> [CodexChatSummary] {
        if reader == nil { try await connect(experimental: true) }
        let account = try await checkedAccount()
        guard account["account"]?["type"]?.string != nil else { throw CodexLiveError.notSignedIn }
        var page: String?
        var cursors = Set<String>()
        var ids = Set<String>()
        var chats: [CodexChatSummary] = []
        repeat {
            var params: [String: JSON] = [
                "cwd": .string(workspace), "currentAccountOnly": .boolean(true), "limit": .integer(50),
                "sortKey": "updated_at"
            ]
            if let page { params["cursor"] = .string(page) }
            let response = try await call("thread/list", .object(params))
            guard let data = response["data"]?.array else { throw CodexLiveError.invalidResponse }
            for thread in data where thread["cwd"]?.string == workspace {
                if let chat = CodexChatSummary(thread), ids.insert(chat.id).inserted { chats.append(chat) }
            }
            page = response["nextCursor"]?.string
            if let page, !cursors.insert(page).inserted { throw CodexLiveError.invalidResponse }
        } while page != nil && cursors.count < 20
        return chats
    }

    public func createSavedChat() async throws -> CodexChatSummary {
        if reader == nil { try await connect(experimental: true) }
        if accountFingerprint != nil { _ = try await checkedAccount() }
        let result = try await call("thread/start", ["cwd": .string(workspace), "ephemeral": .boolean(false)])
        guard let thread = result["thread"], thread["cwd"]?.string == workspace,
              let chat = CodexChatSummary(thread) else { throw CodexLiveError.invalidResponse }
        threadID = chat.id
        savedChat = true
        verifiedChat = true
        return chat
    }

    public func openSavedChat(_ id: String) async throws -> CodexChatSnapshot {
        try await connect(experimental: true)
        if accountFingerprint != nil { _ = try await checkedAccount() }
        savedChat = true
        threadID = id
        _ = try await resumeSavedThread(id)
        let history = try await call("thread/turns/list", [
            "threadId": .string(id), "limit": .integer(30), "itemsView": "full", "sortDirection": "desc"
        ])
        guard let turns = history["data"]?.array else { throw CodexLiveError.invalidResponse }
        verifiedChat = true
        if !turnChanged {
            activeTurnID = turns.first(where: { $0["status"] == "inProgress" })?["id"]?.string
        }
        let messages = turns.reversed().flatMap { turn in
            (turn["items"]?.array ?? []).compactMap { item -> CodexChatMessage? in
                guard var message = CodexChatMessage(item) else { return nil }
                if turn["status"] == "inProgress" && message.role == .assistant {
                    message.streaming = true
                }
                return message
            }
        }
        return CodexChatSnapshot(messages: messages, working: activeTurnID != nil,
                                 hasOlderTurns: history["nextCursor"]?.string != nil)
    }

    public func sendToSavedChat(_ text: String) async throws {
        guard verifiedChat, let threadID, !submitting else { throw CodexLiveError.connectionClosed }
        submitting = true
        defer { submitting = false }
        let input: JSON = .array([["type": "text", "text": .string(text)]])
        if let activeTurnID {
            let result = try await call("turn/steer", [
                "threadId": .string(threadID), "expectedTurnId": .string(activeTurnID), "input": input
            ])
            guard result["turnId"]?.string == activeTurnID else { throw CodexLiveError.wrongTurn }
        } else {
            let result = try await call("turn/start", ["threadId": .string(threadID), "input": input])
            guard let id = result["turn"]?["id"]?.string else { throw CodexLiveError.invalidResponse }
            if activeTurnID == nil, latestCompletedTurn != id { activeTurnID = id }
        }
    }

    public func answer(_ approval: CodexChatApproval, allow: Bool) async throws {
        guard verifiedChat, !closed, let id = approvals.first(where: { $0.value.id == approval.id })?.key,
              let current = approvals[id], allow ? current.canAllow : current.canDecline,
              responsesInFlight.insert(id).inserted else { throw CodexLiveError.expiredApproval }
        do {
            try await send(JSON.reply(id, result: ["decision": allow ? "accept" : "decline"]))
        } catch {
            responsesInFlight.remove(id)
            throw error
        }
    }

    public func pairingFingerprint() async throws -> String {
        if reader == nil { try await connect(experimental: true) }
        let reply = try await checkedAccount()
        guard let fingerprint = Self.fingerprint(reply) else { throw CodexLiveError.accountUnidentified }
        return fingerprint
    }

    private func checkedAccount() async throws -> JSON {
        let reply = try await call("account/read", ["refreshToken": .boolean(false)])
        if let accountFingerprint, Self.fingerprint(reply) != accountFingerprint {
            throw CodexLiveError.accountChanged
        }
        return reply
    }

    private static func fingerprint(_ response: JSON) -> String? {
        guard response["account"]?["type"] == "chatgpt",
              let accountID = response["workspaceRouting"]?["chatgptAccountId"]?.string,
              !accountID.isEmpty else { return nil }
        let email = response["account"]?["email"]?.string ?? ""
        let identity = "\(accountID)\u{0}\(email)"
        return Data(SHA256.hash(data: Data(identity.utf8))).base64EncodedString()
    }

    public func attach() async throws -> CodexLiveTurn {
        try await connect(experimental: false)

        let listing = try await call("thread/list", ["cwd": .string(workspace), "limit": .integer(20)])
        guard let entries = listing["data"]?.array else { throw CodexLiveError.invalidResponse }
        let activeThreads = entries.filter { $0["cwd"]?.string == workspace && $0["status"]?["type"] == "active" }
        guard activeThreads.count < 2 else { throw CodexLiveError.multipleActiveThreads }
        guard let selected = activeThreads.first?["id"]?.string else { throw CodexLiveError.noActiveTurn }
        threadID = selected

        let resume = try await call("thread/resume", ["threadId": .string(selected), "excludeTurns": .boolean(true)])
        guard resume["thread"]?["id"]?.string == selected else { throw CodexLiveError.invalidResponse }
        let history = try await call("thread/turns/list", [
            "threadId": .string(selected), "limit": .integer(3), "itemsView": "full", "sortDirection": "desc"
        ])
        guard let turn = history["data"]?.array?.first(where: { $0["status"] == "inProgress" }),
              let inFlight = turn["id"]?.string,
              !joiningEvents.contains(where: {
                  if case .completed(let id, _) = $0 { return id == inFlight }
                  return false
              }) else { throw CodexLiveError.noActiveTurn }
        let userItem = turn["items"]?.array?.first(where: { $0["type"] == "userMessage" })
        let prompt = userItem?["content"]?.array?.compactMap { $0["text"]?.string }.joined(separator: "\n")
        activeTurnID = inFlight
        joined = true
        for event in joiningEvents where event.turnID == inFlight { emit.yield(event) }
        joiningEvents.removeAll()
        return CodexLiveTurn(threadID: selected, turnID: inFlight, model: resume["model"]?.string, prompt: prompt)
    }

    @discardableResult
    public func steer(_ text: String, expected turn: CodexLiveTurn) async throws -> String {
        guard threadID == turn.threadID, activeTurnID == turn.turnID else { throw CodexLiveError.noActiveTurn }
        let result = try await call("turn/steer", [
            "threadId": .string(turn.threadID),
            "expectedTurnId": .string(turn.turnID),
            "input": .array([["type": "text", "text": .string(text)]])
        ])
        guard result["turnId"]?.string == turn.turnID else { throw CodexLiveError.wrongTurn }
        return turn.turnID
    }

    public func close() { close(CodexLiveError.connectionClosed) }

    public func startSubscriptionCall(offer: String, threadID: String? = nil) async throws
        -> AsyncThrowingStream<CodexCallEvent, any Error> {
        guard offer.hasPrefix("v=0"), offer.utf8.count <= 65_536 else { throw CodexLiveError.invalidResponse }
        guard !endingVoice, voiceAttempt == nil else { throw CodexLiveError.rejected("A call is already open or ending.") }
        let attempt = UUID()
        voiceAttempt = attempt
        do {
            return try await openVoice(offer: offer, on: threadID, attempt: attempt)
        } catch {
            if voiceAttempt == attempt { await endSubscriptionCall() }
            throw error
        }
    }

    private func openVoice(offer: String, on threadID: String?, attempt: UUID) async throws
        -> AsyncThrowingStream<CodexCallEvent, any Error> {
        if verifiedChat {
            guard let threadID, threadID == self.threadID else { throw CodexLiveError.wrongWorkspace }
        } else {
            try await connect(experimental: true)
        }
        let account = try await checkedAccount()
        guard account["account"]?["type"] == "chatgpt" else { throw CodexLiveError.requiresChatGPTSignIn }
        guard voiceAttempt == attempt else { throw CancellationError() }
        let id: String
        if let threadID {
            if !verifiedChat { _ = try await resumeSavedThread(threadID) }
            id = threadID
        } else {
            let created = try await call("thread/start", [
                "cwd": .string(workspace), "modelProvider": "openai", "ephemeral": .boolean(true),
                "sandbox": "read-only", "approvalPolicy": "never", "environments": .array([]),
                "developerInstructions": "This is an isolated voice call. Do not use tools or take external actions."
            ])
            guard let createdID = created["thread"]?["id"]?.string,
                  created["thread"]?["cwd"]?.string == workspace else { throw CodexLiveError.invalidResponse }
            id = createdID
        }
        guard voiceAttempt == attempt else { throw CancellationError() }
        let (stream, continuation) = AsyncThrowingStream<CodexCallEvent, any Error>
            .makeStream(bufferingPolicy: .bufferingNewest(2))
        emitVoice = continuation
        voiceThreadID = id
        _ = try await call("thread/realtime/start", [
            "threadId": .string(id), "version": "v3", "model": "gpt-live-1.1-codex",
            "outputModality": "audio", "includeStartupContext": .boolean(threadID != nil),
            "voiceSessionId": .string(UUID().uuidString.lowercased()),
            "transport": ["type": "webrtc", "sdp": .string(offer)]
        ])
        return stream
    }

    public func endSubscriptionCall() async {
        guard !endingVoice else { return }
        endingVoice = true
        defer { endingVoice = false }
        voiceAttempt = nil
        let id = voiceThreadID
        voiceThreadID = nil
        emitVoice?.finish()
        emitVoice = nil
        if let id, !closed {
            _ = try? await call("thread/realtime/stop", ["threadId": .string(id)])
        }
        if !verifiedChat { close() }
    }

    private func resumeSavedThread(_ id: String) async throws -> JSON {
        let params: JSON = ["threadId": .string(id), "includeTurns": .boolean(false)]
        let read = try await call("thread/read", params)
        guard read["thread"]?["id"]?.string == id,
              read["thread"]?["cwd"]?.string == workspace else { throw CodexLiveError.wrongWorkspace }
        let resume = try await call("thread/resume", ["threadId": .string(id), "excludeTurns": .boolean(true)])
        guard resume["thread"]?["id"]?.string == id,
              resume["thread"]?["cwd"]?.string == workspace else { throw CodexLiveError.wrongWorkspace }
        return resume
    }

    private func connect(experimental: Bool) async throws {
        guard !closed, reader == nil else { throw CodexLiveError.connectionClosed }
        reader = Task { [weak self, transport] in
            do {
                for try await data in transport.incoming {
                    try Task.checkCancellation()
                    await self?.receive(data)
                }
                await self?.close()
            } catch {
                await self?.close(error)
            }
        }
        var parameters: JSON = ["clientInfo": ["name": "riptide", "title": "Riptide", "version": "0.1.0"]]
        if experimental {
            parameters = [
                "clientInfo": parameters["clientInfo"] ?? [:],
                "capabilities": ["experimentalApi": .boolean(true), "requestAttestation": .boolean(false)]
            ]
        }
        _ = try await call("initialize", parameters)
        try await send(["method": "initialized"])
    }

    private func send(_ message: JSON) async throws {
        try await transport.send(JSONEncoder().encode(message))
    }

    private func call(_ method: String, _ params: JSON) async throws -> JSON {
        try Task.checkCancellation()
        guard !closed else { throw CodexLiveError.connectionClosed }
        nextID += 1
        let id = JSON.integer(nextID)
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            await self?.fail(id, CodexLiveError.timedOut)
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                Task {
                    guard pending[id] != nil else { return }
                    do { try await send(["id": id, "method": .string(method), "params": params]) }
                    catch { fail(id, error) }
                }
            }
        } onCancel: {
            Task { await self.fail(id, CancellationError()) }
        }
    }

    private func receive(_ data: Data) {
        guard let packet = try? JSONDecoder().decode(JSON.self, from: data) else { return }
        if let method = packet["method"]?.string {
            if accountFingerprint != nil && method == "account/updated" && packet["id"] == nil {
                close(CodexLiveError.accountChanged)
                return
            }
            if method.hasPrefix("thread/realtime/"), packet["id"] == nil, let voiceThreadID,
               let params = packet["params"], params["threadId"]?.string == voiceThreadID {
                switch method {
                case "thread/realtime/sdp":
                    if let sdp = params["sdp"]?.string, sdp.hasPrefix("v=0"), sdp.utf8.count <= 65_536 {
                        emitVoice?.yield(.answer(sdp))
                    } else {
                        emitVoice?.finish(throwing: CodexLiveError.invalidResponse)
                    }
                case "thread/realtime/error":
                    emitVoice?.finish(throwing: CodexLiveError.rejected(params["message"]?.string ?? "Codex voice failed."))
                case "thread/realtime/closed":
                    self.voiceThreadID = nil
                    emitVoice?.finish()
                case "thread/realtime/item/completed":
                    if savedChat { receiveSavedChat(method, requestID: nil, params: params) }
                default:
                    break
                }
                return
            }
            if savedChat, let threadID, let params = packet["params"], params["threadId"]?.string == threadID {
                receiveSavedChat(method, requestID: packet["id"], params: params)
                return
            }
            guard packet["id"] == nil, let threadID, let params = packet["params"],
                  params["threadId"]?.string == threadID, let event = Self.event(method, params) else { return }
            if !joined {
                if joiningEvents.count == 256 { joiningEvents.removeFirst() }
                joiningEvents.append(event)
            } else if event.turnID == activeTurnID {
                if case .completed = event { activeTurnID = nil }
                emit.yield(event)
            }
        } else if let id = packet["id"], let request = pending.removeValue(forKey: id) {
            if let reason = packet["error"]?["message"]?.string { request.resume(throwing: CodexLiveError.rejected(reason)) }
            else if let result = packet["result"] { request.resume(returning: result) }
            else { request.resume(throwing: CodexLiveError.invalidResponse) }
        }
    }

    private func receiveSavedChat(_ method: String, requestID: JSON?, params: JSON) {
        if let requestID, requestID.rpcID {
            guard approvals[requestID] == nil else { return }
            let command = params["command"]?.string
            let kind = params["kind"]?.string ?? "command"
            let decisions = params["availableDecisions"]?.array
            let plainCommand = method == "item/commandExecution/requestApproval" && kind == "command" &&
                params["networkApprovalContext"]?.isObject != true &&
                params["additionalPermissions"]?.isObject != true && command?.isEmpty == false
            let approval = CodexChatApproval(
                id: UUID(), command: command, cwd: params["cwd"]?.string, reason: params["reason"]?.string,
                canAllow: plainCommand && (decisions?.contains("accept") ?? true),
                canDecline: (method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval")
                    && (decisions?.contains("decline") ?? true)
            )
            approvals[requestID] = approval
            emitChat.yield(.approval(approval))
            return
        }
        if method == "serverRequest/resolved", let id = params["requestId"] {
            responsesInFlight.remove(id)
            if let approval = approvals.removeValue(forKey: id) { emitChat.yield(.approvalResolved(approval.id)) }
            return
        }
        if method == "turn/started", let id = params["turn"]?["id"]?.string {
            turnChanged = true
            activeTurnID = id
            emitChat.yield(.turnStarted)
            return
        }
        if method == "item/completed", let item = params["item"], let message = CodexChatMessage(item),
           message.role == .user {
            emitChat.yield(.message(message))
        }
        if method == "thread/realtime/item/completed", let item = params["item"],
           item["type"] == "transcriptSegment", let id = item["id"]?.string,
           let roleName = item["role"]?.string, let role = ChatRole(rawValue: roleName),
           let text = item["text"]?.string, !text.isEmpty {
            emitChat.yield(.message(CodexChatMessage(id: id, role: role, text: text, streaming: false)))
        }
        if let event = Self.event(method, params) {
            if case .completed(let id, _) = event {
                turnChanged = true
                latestCompletedTurn = id
                if activeTurnID == id { activeTurnID = nil }
            }
            emitChat.yield(.live(event))
        }
    }

    private static func event(_ method: String, _ params: JSON) -> CodexLiveEvent? {
        if method == "turn/completed", let turn = params["turn"],
           let id = turn["id"]?.string, let status = turn["status"]?.string {
            return .completed(turnID: id, status: status)
        }
        guard let turnID = params["turnId"]?.string else { return nil }
        switch method {
        case "turn/diff/updated":
            return params["diff"]?.string.map { .diff(turnID: turnID, patch: $0) }
        case "item/commandExecution/outputDelta":
            return params["delta"]?.string.map { .output(turnID: turnID, text: $0) }
        case "item/agentMessage/delta":
            guard let itemID = params["itemId"]?.string, let text = params["delta"]?.string else { return nil }
            return .assistantDelta(turnID: turnID, itemID: itemID, text: text)
        case "item/completed":
            guard let item = params["item"], item["type"] == "agentMessage",
                  let itemID = item["id"]?.string, let text = item["text"]?.string else { return nil }
            return .assistantCompleted(turnID: turnID, itemID: itemID, text: text)
        default:
            return nil
        }
    }

    private func fail(_ id: JSON, _ error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func close(_ error: any Error) {
        guard !closed else { return }
        closed = true
        activeTurnID = nil
        reader?.cancel()
        reader = nil
        let requests = pending.values
        pending.removeAll()
        for request in requests { request.resume(throwing: error) }
        emit.finish(throwing: error)
        emitVoice?.finish(throwing: error)
        approvals.removeAll()
        responsesInFlight.removeAll()
        emitChat.finish(throwing: error)
    }
}

final class RemoteWebSocketTransport: JSONMessageTransport {
    let incoming: AsyncThrowingStream<Data, any Error>
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private let reader: Task<Void, Never>

    init(url: URL, bearer: String? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        let session = URLSession(configuration: config, delegate: NoRemoteRedirects(), delegateQueue: nil)
        var request = URLRequest(url: url)
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let socket = session.webSocketTask(with: request)
        self.session = session
        self.socket = socket
        let (incoming, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        self.incoming = incoming
        socket.resume()
        reader = Task {
            do {
                while !Task.isCancelled {
                    switch try await socket.receive() {
                    case .string(let message): continuation.yield(Data(message.utf8))
                    case .data(let data): continuation.yield(data)
                    @unknown default: break
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    deinit {
        reader.cancel()
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    func send(_ message: Data) async throws {
        try await socket.send(.string(String(decoding: message, as: UTF8.self)))
    }
}

final class NoRemoteRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
