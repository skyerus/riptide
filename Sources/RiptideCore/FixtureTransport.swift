import Foundation

public struct AgentTarget: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let mainSessionID: String
    public let cwd: String

    public init(id: String, name: String, mainSessionID: String, cwd: String) {
        self.id = id
        self.name = name
        self.mainSessionID = mainSessionID
        self.cwd = cwd
    }

    public static let demos = [
        AgentTarget(id: "openclaw", name: "OpenClaw", mainSessionID: "demo-openclaw-main", cwd: "/demo"),
        AgentTarget(id: "hermes", name: "Hermes", mainSessionID: "demo-hermes-main", cwd: "/demo")
    ]
}

public actor FixtureTransport: ACPTransport {
    public nonisolated let incoming: AsyncThrowingStream<Data, any Error>
    private let output: AsyncThrowingStream<Data, any Error>.Continuation
    private let file: URL?
    private let pace: Duration
    private let historyDelay: Duration
    private let cwd: String
    private let mainSessionID: String
    private var sessions: [SavedSession]
    private var turns: [String: Turn] = [:]
    private var approvals: [JSON: String] = [:]

    private struct SavedSession: Codable {
        let id: String
        var title: String
        var updates: [JSON]
        var model: String?
        var effort: String?
    }

    private struct Turn {
        let id: JSON
        let toolID: String
        let showsRichContent: Bool
        let showsLongStream: Bool
        var work: Task<Void, Never>?
    }

    public init(target: AgentTarget, file: URL? = nil, pace: Duration = .milliseconds(280),
                catalog: [String] = [], historyDelay: Duration = .zero) throws {
        (incoming, output) = AsyncThrowingStream.makeStream()
        self.file = file
        self.pace = pace
        self.historyDelay = historyDelay
        cwd = target.cwd
        mainSessionID = target.mainSessionID
        if let file, FileManager.default.fileExists(atPath: file.path) {
            sessions = try JSONDecoder().decode([SavedSession].self, from: Data(contentsOf: file))
        } else {
            sessions = [
                SavedSession(id: target.mainSessionID, title: "Main Chat", updates: [
                    Self.chunk("agent_message_chunk", id: "welcome", text:
                        "**This is your main chat.** Come back here to pick up where you left off.\n\n"
                        + "Ask me for a quick project rundown, or start another chat to keep a topic separate.")
                ])
            ]
            sessions += catalog.enumerated().map { index, title in
                let id = "\(target.id)-sample-\(index + 1)"
                return SavedSession(id: id, title: title, updates: [
                    Self.chunk("agent_message_chunk", id: "arrival-\(id)", text: "Fixture chat: \(title)")
                ])
            }
        }
    }

    deinit { output.finish() }

    public func send(_ message: Data) async throws {
        let packet = try JSONDecoder().decode(JSON.self, from: message)
        let params = packet["params"] ?? [:]
        let sessionID = params["sessionId"]?.string ?? ""
        guard let method = packet["method"]?.string else {
            if let id = packet["id"], let session = approvals.removeValue(forKey: id) {
                let allowed = packet["result"]?["outcome"]?["optionId"] == "allow-once"
                continueTurn(in: session, allowed: allowed)
            }
            return
        }
        if method == "session/cancel" {
            cancel(sessionID)
            return
        }
        guard let id = packet["id"] else { return }
        do {
            switch method {
            case "initialize":
                emit(.reply(id, result: [
                    "protocolVersion": .integer(1),
                    "agentCapabilities": ["loadSession": .boolean(true), "sessionCapabilities": ["list": [:]],
                                          "promptCapabilities": ["image": .boolean(true)],
                                          "_meta": ["riptide.app/attachments": .integer(1)]]
                ]))
            case "session/list":
                emit(.reply(id, result: ["sessions": .array(sessions.map { session in
                    ["sessionId": .string(session.id), "title": .string(session.title), "cwd": .string(cwd)]
                })]))
            case "session/new":
                let newID = UUID().uuidString
                sessions.insert(SavedSession(id: newID, title: "Untitled chat", updates: []), at: 0)
                do { try save() }
                catch { sessions.removeFirst(); throw error }
                emit(.reply(id, result: ["sessionId": .string(newID), "configOptions": configuration(sessions[0])]))
                reportUsage(for: sessions[0])
            case "session/load":
                if historyDelay > .zero { try await Task.sleep(for: historyDelay) }
                guard let index = index(of: sessionID) else {
                    emit(.failure(id, code: -32602, message: "This conversation is no longer available."))
                    return
                }
                for update in sessions[index].updates { stream(update, in: sessionID) }
                reportUsage(for: sessions[index])
                emit(.reply(id, result: ["configOptions": configuration(sessions[index])]))
            case "session/set_config_option":
                guard let index = index(of: sessionID), let option = params["configId"]?.string,
                      let value = params["value"]?.string,
                      let allowed = configuration(sessions[index]).array?.first(where: { $0["id"]?.string == option }),
                      allowed["options"]?.array?.contains(where: { $0["value"]?.string == value }) == true else {
                    emit(.failure(id, code: -32602, message: "This option is not available in this chat."))
                    return
                }
                let previous = sessions[index]
                if option == "model" {
                    sessions[index].model = value
                    if value == "atlas-mini", previous.effort == "high" { sessions[index].effort = "medium" }
                } else {
                    sessions[index].effort = value
                }
                do { try save() }
                catch { sessions[index] = previous; throw error }
                emit(.reply(id, result: ["configOptions": configuration(sessions[index])]))
                reportUsage(for: sessions[index])
            case "_riptide/session/steer":
                guard let text = params["text"]?.string, !text.isEmpty else {
                    emit(.failure(id, code: -32602, message: "Enter a follow-up message."))
                    return
                }
                if turns[sessionID] != nil {
                    try record(Self.chunk("user_message_chunk", id: UUID().uuidString, text: text),
                               in: sessionID, live: false)
                    emit(.reply(id, result: ["status": "steered"]))
                } else {
                    emit(.reply(id, result: ["status": "idle"]))
                }
            case "riptide/stageAttachments":
                let paths: [JSON] = (params["files"]?.array ?? []).compactMap { file in
                    guard let name = file["name"]?.string, let encoded = file["dataBase64"]?.string,
                          Data(base64Encoded: encoded) != nil else { return nil }
                    return .string("/fixture/attachments/\(name)")
                }
                emit(.reply(id, result: ["paths": .array(paths)]))
            case "session/prompt":
                guard turns[sessionID] == nil, let index = index(of: sessionID),
                      let text = params["prompt"]?.array?.first?["text"]?.string else {
                    emit(.failure(id, code: -32602, message: "This conversation is unavailable or already working."))
                    return
                }
                if sessions[index].title == "Untitled chat" { sessions[index].title = String(text.prefix(48)) }
                let item = sessions.remove(at: index)
                sessions.insert(item, at: 0)
                try record(Self.chunk("user_message_chunk", id: UUID().uuidString, text: text), in: sessionID, live: false)
                let toolID = UUID().uuidString
                try record([
                    "sessionUpdate": "tool_call", "toolCallId": .string(toolID),
                    "title": "Review context", "status": "pending"
                ], in: sessionID)
                turns[sessionID] = Turn(id: id, toolID: toolID,
                    showsRichContent: text.localizedCaseInsensitiveContains("formatting demo"),
                    showsLongStream: text.localizedCaseInsensitiveContains("streaming demo"))
                prepare(in: sessionID, id: id, needsApproval: text.localizedCaseInsensitiveContains("approval"))
            default:
                emit(.failure(id, code: -32601, message: "Unsupported fixture method."))
            }
        } catch {
            emit(.failure(id, code: -32603, message: "Could not save the demo conversation."))
        }
    }

    private func prepare(in sessionID: String, id: JSON, needsApproval: Bool) {
        turns[sessionID]?.work = Task { [weak self, pace] in
            do { try await Task.sleep(for: pace) } catch { return }
            await self?.begin(in: sessionID, id: id, needsApproval: needsApproval)
        }
    }

    private func begin(in sessionID: String, id: JSON, needsApproval: Bool) {
        guard let turn = turns[sessionID], turn.id == id else { return }
        if needsApproval {
            let approvalID = JSON.string("permission-\(UUID().uuidString)")
            approvals[approvalID] = sessionID
            emit(.request("session/request_permission", id: approvalID, params: [
                "sessionId": .string(sessionID),
                "toolCall": ["toolCallId": .string(turn.toolID), "title": "Review sample context"],
                "options": .array([
                    ["optionId": "allow-once", "name": "Allow once", "kind": "allow_once"],
                    ["optionId": "deny", "name": "Deny", "kind": "reject_once"]
                ])
            ]))
        } else {
            continueTurn(in: sessionID, allowed: true)
        }
    }

    private func continueTurn(in sessionID: String, allowed: Bool) {
        guard let turn = turns[sessionID] else { return }
        let id = turn.id
        if !allowed {
            do {
                try recordTool(turn, status: "failed", in: sessionID)
                try record(Self.chunk("agent_message_chunk", id: UUID().uuidString,
                                      text: "I skipped the sample action. Nothing was run."), in: sessionID)
                finish(sessionID, reason: "end_turn")
            } catch { fail(sessionID) }
            return
        }
        do { try recordTool(turn, status: "in_progress", in: sessionID) }
        catch { fail(sessionID); return }
        turns[sessionID]?.work = Task { [weak self, pace] in
            let messageID = UUID().uuidString
            let chunks = turn.showsLongStream ? Self.longStreamChunks : turn.showsRichContent ? Self.richContentChunks : [
                "Here’s a quick rundown of the demo workspace.\n\n",
                "| Area | Sta",
                "tus |\n| --- | --- |\n| Main chat | Ready |\n",
                "| Other chats | Saved separately |\n\n",
                "You can come back to this conversation whenever you need it."
            ]
            for text in chunks {
                do { try await Task.sleep(for: pace) } catch { return }
                guard await self?.append(text, messageID: messageID, in: sessionID, id: id) == true else { return }
            }
            await self?.complete(sessionID, id: id)
        }
    }

    private static let richContentChunks = [
        "## Agent handoff\n\nThe **same turn** stays on your host.\n\n",
        "~~~mermaid\nflowchart TD\naccTitle: Agent handoff\naccDescr: Riptide watches Codex on the host.\n",
        "    A[Riptide] -->|watch| B[Codex]\n    B --> C[Host]\n~~",
        "~\n\n",
        "~~~swift\nstruct Turn {\n    let id: String\n",
        "    let message = \"Connected\"\n}\n~~~\n\n",
        "~~~diff\ndiff --git a/App.swift b/App.swift\n--- a/App.swift\n+++ b/App.swift\n",
        "@@ -4,2 +4,2 @@\n let turn = activeTurn\n- reconnect(to: turn)\n+ watch(turn)\n~~~\n\n",
        "Read the [example guide](https://example.com/guide) or visit https://example.org.\n\nFormatting demo complete."
    ]

    private static let longStreamChunks = (1...27).map { index in
        "## Update \(index)\n\nThe simulated agent is checking the next part of the workspace. "
        + "This paragraph adds new content without changing previous updates.\n\n"
    } + ["Long stream complete."]

    private func append(_ text: String, messageID: String, in sessionID: String, id: JSON) -> Bool {
        guard turns[sessionID]?.id == id else { return false }
        do {
            try record(Self.chunk("agent_message_chunk", id: messageID, text: text), in: sessionID)
            return true
        } catch {
            fail(sessionID)
            return false
        }
    }

    private func complete(_ sessionID: String, id: JSON) {
        guard let turn = turns[sessionID], turn.id == id else { return }
        do {
            try recordTool(turn, status: "completed", in: sessionID)
            finish(sessionID, reason: "end_turn")
        } catch { fail(sessionID) }
    }

    private func cancel(_ sessionID: String) {
        guard let turn = turns[sessionID] else { return }
        turn.work?.cancel()
        do {
            try recordTool(turn, status: "failed", in: sessionID)
            finish(sessionID, reason: "cancelled")
        } catch { fail(sessionID) }
    }

    private func removeTurn(_ sessionID: String) -> Turn? {
        approvals = approvals.filter { $0.value != sessionID }
        return turns.removeValue(forKey: sessionID)
    }

    private func finish(_ sessionID: String, reason: String) {
        guard let turn = removeTurn(sessionID) else { return }
        if let index = index(of: sessionID) { reportUsage(for: sessions[index]) }
        emit(.reply(turn.id, result: ["stopReason": .string(reason)]))
    }

    private func fail(_ sessionID: String) {
        guard let turn = removeTurn(sessionID) else { return }
        emit(.failure(turn.id, code: -32603, message: "Could not save the demo conversation."))
    }

    private func recordTool(_ turn: Turn, status: String, in sessionID: String) throws {
        try record([
            "sessionUpdate": "tool_call_update", "toolCallId": .string(turn.toolID), "status": .string(status)
        ], in: sessionID)
    }

    private func record(_ update: JSON, in sessionID: String, live: Bool = true) throws {
        guard let index = index(of: sessionID) else { throw ACPError.malformedResponse }
        sessions[index].updates.append(update)
        do { try save() }
        catch { sessions[index].updates.removeLast(); throw error }
        if live { stream(update, in: sessionID) }
    }

    private func stream(_ update: JSON, in sessionID: String) {
        emit(.notification("session/update", params: ["sessionId": .string(sessionID), "update": update]))
    }

    private func emit(_ response: JSON) {
        if let data = try? JSONEncoder().encode(response) { output.yield(data) }
    }

    private func index(of sessionID: String) -> Int? {
        sessions.firstIndex { $0.id == sessionID }
    }

    private func save() throws {
        guard let file else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(sessions).write(to: file, options: .atomic)
    }

    private func configuration(_ session: SavedSession) -> JSON {
        let hermes = mainSessionID == "demo-hermes-main"
        let models: [JSON] = hermes ? ["gpt-6.2-sol", "gpt-6.2-astra", "gpt-6.1-sol", "gpt-6.1-sol-900k"].map { model in
            ["value": .string("openai-codex:\(model)"), "name": .string("ChatGPT or Codex Subscription · \(model)")]
        } : [
            ["value": "atlas", "name": "Atlas", "description": "General-purpose demo model"],
            ["value": "atlas-mini", "name": "Atlas Mini", "description": "Lightweight demo model"]
        ]
        let model = models.first { $0["value"]?.string == session.model }?["value"]?.string
            ?? (hermes ? "openai-codex:gpt-6.2-sol" : "atlas")
        let effortValues = hermes ? ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
            : model == "atlas" ? ["low", "medium", "high"] : ["low", "medium"]
        let efforts: [JSON] = effortValues.map { ["value": .string($0), "name": .string($0)] }
        return .array([
            ["id": "model", "name": "Model", "category": "model", "type": "select",
             "currentValue": .string(model), "options": .array(models)],
            ["id": "effort", "name": "Reasoning effort", "category": "thought_level", "type": "select",
             "currentValue": .string(session.effort ?? (hermes ? "xhigh" : "medium")), "options": .array(efforts)]
        ])
    }

    private func reportUsage(for session: SavedSession) {
        let textBytes = session.updates.reduce(0) { total, update in
            total + (update["content"]?["text"]?.string?.utf8.count ?? 0)
        }
        let baseline = session.id == mainSessionID ? 28_400 : 1_600
        stream([
            "sessionUpdate": "usage_update",
            "used": .integer(baseline + textBytes / 4),
            "size": .integer(session.model == "atlas-mini" ? 64_000 : 128_000)
        ], in: session.id)
    }

    private static func chunk(_ kind: String, id: String, text: String) -> JSON {
        ["sessionUpdate": .string(kind), "messageId": .string(id),
         "content": ["type": "text", "text": .string(text)]]
    }
}
