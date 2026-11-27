import Foundation
import Testing
@testable import RiptideCore

struct ACPCapabilityTests {
    @Test func restrictedSSHCanInitializeWithAnOlderWrapper() async throws {
        let transport = ScriptedTransport { request in
            let id = try #require(request["id"])
            #expect(request["method"] == "initialize")
            let capabilities = request["params"]?["clientCapabilities"]
            if id == .integer(1) {
                #expect(capabilities?["_meta"]?["app.riptide.assistantProgress"] == .boolean(true))
                return [.failure(id, code: -32602, message: "Unsupported capability")]
            }
            #expect(id == .integer(2))
            #expect(capabilities == [:])
            return [.reply(id, result: ["protocolVersion": .integer(1), "agentCapabilities": [
                "loadSession": .boolean(true),
            ]])]
        }
        let client = ACPClient(transport: transport, restrictedSSH: true)
        #expect(try await client.canLoadSessions())
        await client.close()
    }

    @Test func codexStagesFilesAndSendsPhotosAsVisionInput() async throws {
        let thread: JSON = ["id": "selected", "cwd": "/disposable"]
        let photo = ChatAttachment(name: "Photo.png", data: Data([1, 2, 3]), imageMIMEType: "image/png")
        let document = ChatAttachment(name: "Report.pdf", data: Data([37, 80, 68, 70]))
        let stagedPath = "/test-codex-home/attachments/af98aad7-a042-4c6e-9476-bbf1b5e4ea40/1-Photo.png"
        let transport = ScriptedTransport { request in
            let method = request["method"]?.string
            if method == "initialized" { return [] }
            let id = try #require(request["id"])
            let params = request["params"]
            switch method {
            case "initialize":
                return [.reply(id, result: ["codexHome": "/test-codex-home"])]
            case "thread/read", "thread/resume":
                return [.reply(id, result: ["thread": thread])]
            case "thread/turns/list":
                return [.reply(id, result: ["data": .array([])])]
            case "fs/createDirectory":
                #expect(params?["path"]?.string?.hasPrefix("/test-codex-home/attachments/") == true)
                return [.reply(id, result: [:])]
            case "fs/writeFile":
                let path = try #require(params?["path"]?.string)
                #expect(path.hasPrefix("/test-codex-home/attachments/"))
                if path.hasSuffix("/1-Photo.png") {
                    #expect(params?["dataBase64"]?.string == photo.data.base64EncodedString())
                } else {
                    #expect(path.hasSuffix("/2-Report.pdf"))
                    #expect(params?["dataBase64"]?.string == document.data.base64EncodedString())
                }
                return [.reply(id, result: [:])]
            case "fs/readFile":
                #expect(params?["path"]?.string == stagedPath)
                return [.reply(id, result: ["dataBase64": .string(photo.data.base64EncodedString())])]
            case "turn/start":
                #expect(params?["threadId"] == "selected")
                let input = try #require(params?["input"]?.array)
                #expect(input.count == 2)
                #expect(input.first?["type"] == "localImage")
                #expect(input.first?["path"]?.string?.hasSuffix("/1-Photo.png") == true)
                #expect(input.last?["text"]?.string?.hasSuffix("/2-Report.pdf") == true)
                #expect(input.last?["text"]?.string?.contains("Attached file: Report.pdf") == true)
                let message = CodexChatMessage(["id": "message", "type": "userMessage", "content": .array(input)])
                let photoPath = try #require(input.first?["path"]?.string)
                #expect(message?.text.hasPrefix("Attached file: Report.pdf") == true)
                #expect(message?.photos == [.init(name: "Photo.png", source: .codexPath(photoPath))])
                return [.reply(id, result: ["turn": ["id": "new-turn"]])]
            default:
                Issue.record("Unexpected attachment RPC: \(method ?? "missing")")
                return [.failure(id, code: -32601, message: "Unexpected request")]
            }
        }
        let client = CodexLiveClient(transport: transport, workspace: "/disposable")
        _ = try await client.openSavedChat("selected")
        try await client.sendToSavedChat("", attachments: [photo, document])
        #expect(try await client.readTranscriptPhoto(at: stagedPath) == photo.data)
        await #expect(throws: CodexLiveError.invalidResponse) {
            _ = try await client.readTranscriptPhoto(at: "/unrelated/1-Photo.png")
        }
        await client.close()
    }

    @Test func acpStagesBinaryFilesAndSendsImageContentBlocks() async throws {
        let photo = ChatAttachment(name: "Photo.jpg", data: Data([1, 2, 3]), imageMIMEType: "image/jpeg")
        let document = ChatAttachment(name: "Report.pdf", data: Data([37, 80, 68, 70]))
        let transport = ScriptedTransport { request in
            let id = try #require(request["id"])
            let params = request["params"]
            switch request["method"]?.string {
            case "initialize":
                return [.reply(id, result: ["protocolVersion": .integer(1), "agentCapabilities": [
                    "promptCapabilities": ["image": .boolean(true)],
                    "_meta": ["riptide.app/attachments": .integer(1)],
                ]])]
            case "riptide/stageAttachments":
                #expect(params?["files"]?.array == [[
                    "name": "Report.pdf", "dataBase64": .string(document.data.base64EncodedString()),
                ]])
                return [.reply(id, result: ["paths": .array(["/tmp/private/1-Report.pdf"])])]
            case "session/prompt":
                #expect(params?["sessionId"] == "selected")
                #expect(params?["prompt"]?.array == [
                    ["type": "text", "text": "Review these"],
                    ["type": "text", "text": "Attached file: Report.pdf\nHost path: /tmp/private/1-Report.pdf"],
                    ["type": "text", "text": "Attached image: Photo.jpg"],
                    ["type": "image", "mimeType": "image/jpeg", "data": .string(photo.data.base64EncodedString())],
                ])
                return [.reply(id, result: ["stopReason": "end_turn"])]
            default:
                Issue.record("Unexpected ACP attachment RPC")
                return [.failure(id, code: -32601, message: "Unexpected request")]
            }
        }
        let client = ACPClient(transport: transport, restrictedSSH: true)
        #expect(try await client.prompt("Review these", sessionID: "selected", attachments: [photo, document]) == "end_turn")
        await client.close()
    }

    @Test(arguments: [false, true]) func codexRoutesContextUsageToSavedChatsAndDesktopWatchers(watching: Bool) async throws {
        let thread: JSON = ["id": "selected", "cwd": "/disposable", "status": ["type": "active"]]
        let transport = ScriptedTransport { request in
            let method = request["method"]?.string
            if method == "initialized" { return [] }
            let id = try #require(request["id"])
            switch method {
            case "initialize":
                return [.reply(id, result: [:])]
            case "thread/list":
                return [.reply(id, result: ["data": .array([thread])])]
            case "thread/read", "thread/resume":
                return [.reply(id, result: ["thread": thread])]
            case "thread/turns/list":
                let usage: JSON = ["last": ["totalTokens": .integer(8_000)], "modelContextWindow": .integer(32_000)]
                return [.notification("thread/tokenUsage/updated", params: [
                    "threadId": "unrelated", "turnId": "active", "tokenUsage": .null
                ]), .notification("thread/tokenUsage/updated", params: [
                    "threadId": "selected", "turnId": "active", "tokenUsage": usage
                ]), .reply(id, result: ["data": .array([["id": "active", "status": "inProgress"]])])]
            default:
                return [.failure(id, code: -32601, message: "Unexpected request")]
            }
        }
        let client = CodexLiveClient(transport: transport, workspace: "/disposable")
        let expected = CodexLiveEvent.context(turnID: "active", usage: ContextUsage(used: 8_000, capacity: 32_000))
        if watching {
            _ = try await client.attach()
            var events = client.events.makeAsyncIterator()
            #expect(try await events.next() == expected)
        } else {
            _ = try await client.openSavedChat("selected")
            var events = client.chatEvents.makeAsyncIterator()
            if case .live(let context) = try await events.next() { #expect(context == expected) }
            else { Issue.record("Expected context usage for the selected chat") }
        }
        await client.close()
    }

    @Test func codexComposerUsesNativeThreadSettingsAndModelCapabilities() async throws {
        let thread: JSON = ["id": "selected", "cwd": "/disposable"]
        let transport = ScriptedTransport { request in
            let method = request["method"]?.string
            if method == "initialized" { return [] }
            let id = try #require(request["id"])
            let params = request["params"]
            switch method {
            case "initialize":
                #expect(params?["capabilities"]?["experimentalApi"] == .boolean(true))
                return [.reply(id, result: [:])]
            case "thread/read":
                return [.reply(id, result: ["thread": thread])]
            case "thread/resume":
                return [.reply(id, result: ["thread": thread, "model": "selected-model", "modelProvider": "openai",
                                            "serviceTier": "default", "reasoningEffort": "medium"])]
            case "thread/turns/list":
                return [.reply(id, result: ["data": .array([])])]
            case "model/list":
                #expect(params?["modelProvider"] == "openai")
                return [.reply(id, result: ["data": .array([
                    ["model": "selected-model", "defaultServiceTier": "priority", "supportedReasoningEfforts": .array([
                        ["reasoningEffort": "medium"], ["reasoningEffort": "high"]
                    ]), "serviceTiers": .array([["id": "ultrafast", "name": "Ultrafast"], ["id": "priority", "name": "Fast"]])],
                    ["model": "other-model", "defaultReasoningEffort": "low", "supportedReasoningEfforts": .array([
                        ["reasoningEffort": "low"]
                    ])]
                ])])]
            case "thread/settings/update":
                if let tier = params?["serviceTier"]?.string {
                    #expect(params == ["threadId": "selected", "serviceTier": .string(tier)])
                    #expect(["priority", "default"].contains(tier))
                    return [.notification("thread/settings/updated", params: [
                        "threadId": "selected", "threadSettings": ["model": "selected-model", "modelProvider": "openai",
                                                                   "serviceTier": .string(tier), "effort": "medium"]
                    ]), .reply(id, result: [:])]
                }
                if params?["model"] != nil {
                    #expect(params == ["threadId": "selected", "model": "other-model", "effort": "low"])
                } else {
                    #expect(params == ["threadId": "selected", "effort": "high"])
                }
                return [.reply(id, result: [:])]
            default:
                Issue.record("Unexpected Codex request: \(method ?? "missing")")
                return [.failure(id, code: -32601, message: "Unexpected request")]
            }
        }
        let client = CodexLiveClient(transport: transport, workspace: "/disposable")
        _ = try await client.openSavedChat("selected")
        await client.discoverSavedChatConfiguration()
        var events = client.chatEvents.makeAsyncIterator()
        _ = try await events.next()
        guard case .configOptions(let initial) = try await events.next() else {
            Issue.record("Expected the thread's model, intelligence, and speed settings")
            return
        }
        #expect(initial.first { $0.category == .serviceTier }?.fastMode == false)
        let fast = try await client.setSavedChatConfigOption("service_tier", value: "fast")
        #expect(fast.first { $0.category == .serviceTier }?.fastMode == true)
        let normal = try await client.setSavedChatConfigOption("service_tier", value: "default")
        #expect(normal.first { $0.category == .serviceTier }?.fastMode == false)
        let high = try await client.setSavedChatConfigOption("effort", value: "high")
        #expect(high.first { $0.category == .thoughtLevel }?.currentValue == "high")
        let changed = try await client.setSavedChatConfigOption("model", value: "other-model")
        #expect(changed.first { $0.category == .model }?.currentValue == "other-model")
        #expect(changed.first { $0.category == .thoughtLevel }?.currentValue == "low")
        #expect(changed.allSatisfy { $0.category != .serviceTier })
        await client.close()
    }

    @Test func codexInputAndStopAreScopedToTheCurrentRequestAndTurn() async throws {
        let thread: JSON = ["id": "selected", "cwd": "/disposable"]
        let transport = ScriptedTransport { request in
            let method = request["method"]?.string
            if method == "initialized" { return [] }
            let id = try #require(request["id"])
            let params = request["params"]
            switch method {
            case "initialize":
                return [.reply(id, result: [:])]
            case "thread/read", "thread/resume":
                return [.reply(id, result: ["thread": thread])]
            case "thread/turns/list":
                let choices: JSON = .array([["id": "choice", "header": "Pick", "question": "What should I use?",
                                            "options": .array([["label": "This one", "description": "One option"]])]])
                return [.request("item/tool/requestUserInput", id: "input-wire", params: [
                    "threadId": "selected", "turnId": "current", "questions": choices
                ]), .reply(id, result: ["data": .array([["id": "current", "status": "inProgress"]])])]
            case "turn/interrupt":
                #expect(params?["threadId"] == "selected")
                #expect(params?["turnId"] == "current")
                return [.reply(id, result: [:])]
            case nil:
                #expect(id == "input-wire")
                #expect(request["result"]?["answers"]?["choice"]?["answers"] == .array(["This one"]))
                return [.notification("serverRequest/resolved", params: ["threadId": "selected", "requestId": id])]
            default:
                Issue.record("Unexpected Codex request")
                return []
            }
        }
        let client = CodexLiveClient(transport: transport, workspace: "/disposable")
        _ = try await client.openSavedChat("selected")
        var events = client.chatEvents.makeAsyncIterator()
        guard case .approval(let request) = try await events.next() else {
            Issue.record("Expected a scoped input request")
            return
        }
        #expect(request.isInput)
        #expect(request.questions?.first?.options.map(\.label) == ["This one"])
        await #expect(throws: CodexLiveError.rejected("Answer each question using an offered choice or an allowed text response.")) {
            try await client.answerInput(request, values: ["choice": "unoffered"])
        }
        try await client.answerInput(request, values: ["choice": "This one"])
        guard case .approvalResolved(let resolved) = try await events.next() else {
            Issue.record("Expected acknowledgement from Codex")
            return
        }
        #expect(resolved == request.id)
        await #expect(throws: CodexLiveError.expiredApproval) {
            try await client.answerInput(request, values: ["choice": "This one"])
        }
        try await client.interruptSavedTurn()
        await client.close()
    }

    @Test func aSavedCodexChatCannotReopenAfterAccountSwitch() async throws {
        let transport = ScriptedTransport { request in
            let method = request["method"]?.string
            if method == "initialized" { return [] }
            let id = try #require(request["id"])
            if method == "initialize" { return [.reply(id, result: [:])] }
            #expect(method == "account/read")
            return [.reply(id, result: [
                "account": ["type": "chatgpt"],
                "workspaceRouting": ["chatgptAccountId": "different-account"]
            ])]
        }
        let client = CodexLiveClient(transport: transport, workspace: "/disposable", accountFingerprint: "paired-account")
        await #expect(throws: CodexLiveError.accountChanged) {
            try await client.openSavedChat("saved")
        }
        await client.close()
    }

    @Test func ACPReissuesApprovalOnlyOnTheCurrentConnection() async throws {
        func connection() -> ACPClient {
            let transport = ScriptedTransport { request in
                let id = try #require(request["id"])
                switch request["method"]?.string {
                case "initialize":
                    return [.reply(id, result: [
                        "protocolVersion": .integer(1), "agentCapabilities": ["loadSession": .boolean(true)]
                    ])]
                case "session/load":
                    #expect(request["params"]?["sessionId"] == "saved")
                    return [
                        .request("session/request_permission", id: "wire-approval", params: [
                            "sessionId": "saved", "toolCall": ["title": "Sample command"],
                            "options": .array([["optionId": "no", "name": "Deny", "kind": "reject_once"]])
                        ]),
                        .reply(id, result: [:])
                    ]
                default:
                    #expect(id == "wire-approval")
                    #expect(request["result"]?["outcome"]?["optionId"] == "no")
                    return []
                }
            }
            return ACPClient(transport: transport)
        }
        let first = connection()
        _ = try await first.load(sessionID: "saved", cwd: "/disposable")
        var firstEvents = first.events.makeAsyncIterator()
        let firstEvent = await firstEvents.next()
        guard case .permission(let previous) = firstEvent else {
            Issue.record("No approval was received while loading")
            return
        }
        await first.close()
        let next = connection()
        _ = try await next.load(sessionID: "saved", cwd: "/disposable")
        var nextEvents = next.events.makeAsyncIterator()
        let nextEvent = await nextEvents.next()
        guard case .permission(let current) = nextEvent else {
            Issue.record("No approval was reissued by the backend")
            return
        }
        #expect(previous.id != current.id)
        await #expect(throws: ACPError.permissionExpired) {
            try await next.resolve(previous.id, optionID: "no")
        }
        try await next.resolve(current.id, optionID: "no")
        await next.close()
    }

    @Test func sameChatVoiceDoesNotReplaceApprovalConnection() async throws {
        let verifiedThread: JSON = ["id": "existing", "cwd": "/disposable"]
        let transport = ScriptedTransport { request in
            let method = request["method"]?.string
            if method == "initialized" { return [] }
            let id = try #require(request["id"])
            let params = request["params"]
            if method == nil {
                #expect(id == .integer(123))
                #expect(request["result"]?["decision"] == "decline")
                return [.notification("serverRequest/resolved", params: ["threadId": "existing", "requestId": id])]
            }
            switch method {
            case "initialize":
                return [.reply(id, result: [:])]
            case "thread/read":
                #expect(params?["threadId"] == "existing")
                return [.reply(id, result: ["thread": verifiedThread])]
            case "thread/resume":
                #expect(params?["threadId"] == "existing")
                return [
                    .request("item/commandExecution/requestApproval", id: .integer(444), params: [
                        "threadId": "another", "command": "echo outside"
                    ]),
                    .request("item/commandExecution/requestApproval", id: .integer(123), params: [
                        "threadId": "existing", "turnId": "running", "command": "echo check", "cwd": "/disposable",
                        "availableDecisions": .array(["accept", "decline"])
                    ]),
                    .reply(id, result: ["thread": verifiedThread])
                ]
            case "thread/turns/list":
                return [.reply(id, result: ["data": .array([
                    ["id": "running", "status": "inProgress", "startedAt": .integer(1_700_000_000), "items": .array([
                        ["id": "message-0", "type": "userMessage",
                         "content": .array([["type": "text", "text": "saved conversation"]])]
                    ])],
                    ["id": "previous", "status": "completed", "items": .array([
                        ["id": "previous-user", "type": "userMessage",
                         "content": .array([["type": "text", "text": "older prompt"]])],
                        ["id": "previous-tool", "type": "commandExecution", "command": "echo older"],
                        ["id": "previous-agent", "type": "agentMessage", "text": "older reply"]
                    ])]
                ])])]
            case "account/read":
                return [.reply(id, result: ["account": ["type": "chatgpt"]])]
            case "thread/realtime/listVoices":
                return [.reply(id, result: ["voices": ["v1": .array(["arbor"]), "v3": .array(["juniper", "cove"])]])]
            case "thread/realtime/start":
                #expect(params?["threadId"] == "existing")
                #expect(params?["voice"] == "juniper")
                #expect(params?["includeStartupContext"] == .boolean(true))
                #expect(params?["flushTranscriptTailOnSessionEnd"] == nil)
                return [
                    .notification("thread/realtime/started", params: [
                        "threadId": "existing", "realtimeSessionId": "this-call", "version": "v3"
                    ]),
                    .notification("thread/realtime/sdp", params: ["threadId": "existing", "sdp": "v=0 same-chat"]),
                    .notification("thread/realtime/transcript/delta", params: [
                        "threadId": "existing", "role": "user", "delta": "Check"
                    ]),
                    .reply(id, result: [:])
                ]
            case "thread/realtime/stop":
                #expect(params?["threadId"] == "existing")
                return [
                    .reply(id, result: [:]),
                    .notification("thread/realtime/item/completed", params: ["threadId": "existing", "item": [
                        "id": "wrong", "type": "transcriptSegment", "role": "user",
                        "realtimeSessionId": "another-call", "text": "Must not be saved"
                    ]]),
                    .notification("thread/realtime/item/completed", params: ["threadId": "existing", "item": [
                        "id": "speech", "type": "transcriptSegment", "role": "user",
                        "realtimeSessionId": "this-call", "text": "Check the draft."
                    ]]),
                    .notification("thread/realtime/closed", params: ["threadId": "existing", "reason": "requested"])
                ]
            case "turn/steer":
                #expect(params?["expectedTurnId"] == "running")
                if params?["input"]?.array?.first?["text"] == "send at completion" {
                    return [.failure(id, code: -32600, message: "no active turn to steer")]
                }
                return [.reply(id, result: ["turnId": "running"])]
            case "turn/start":
                #expect(params?["input"]?.array?.first?["text"] == "send at completion")
                return [.reply(id, result: ["turn": ["id": "next"]])]
            default:
                Issue.record("Unexpected chat or call method: \(method ?? "missing")")
                return [.failure(id, code: -32601, message: "Unexpected request")]
            }
        }
        let client = CodexLiveClient(transport: transport, workspace: "/disposable")
        let snapshot = try await client.openSavedChat("existing")
        #expect(snapshot.working)
        #expect(snapshot.activeTurnStartedAt?.timeIntervalSince1970 == 1_700_000_000)
        #expect(snapshot.messages.last?.text == "saved conversation")
        #expect(snapshot.messages.last?.receipt == .delivered)
        #expect(snapshot.messages.first?.receipt == .seen)
        #expect(snapshot.turns.first?.progress.items.first?.title == "echo older")
        #expect(snapshot.turns.first?.progress.items.first?.state == .finished)
        #expect(snapshot.progress.items.isEmpty)
        var chatEvents = client.chatEvents.makeAsyncIterator()
        let event = try await chatEvents.next()
        guard case .approval(let approval) = event else {
            Issue.record("Expected the resumed chat's pending request")
            return
        }
        #expect(approval.command == "echo check")
        #expect(try await client.subscriptionVoices() == ["juniper", "cove"])
        let voice = try await client.startSubscriptionCall(offer: "v=0\r\n", threadID: "existing", voice: "juniper")
        var voiceEvents = voice.makeAsyncIterator()
        #expect(try await voiceEvents.next() == .answer("v=0 same-chat"))
        #expect(await client.endSubscriptionCall() == [.init(role: .user, text: "Check the draft.")])
        try await client.answer(approval, allow: false)
        if case .approvalResolved(let id) = try await chatEvents.next() {
            #expect(id == approval.id)
        } else {
            Issue.record("Expected the host to clear the declined approval")
        }
        await #expect(throws: CodexLiveError.self) {
            try await client.sendToSavedChat("start too soon", startOnly: true)
        }
        #expect(try await client.sendToSavedChat("keep going") == .steered(turnID: "running"))
        #expect(try await client.sendToSavedChat("send at completion") == .started(turnID: "next"))
        await client.close()
    }

    @Test func savedChatRejectsOtherWorkspaceBeforeResuming() async throws {
        let transport = ScriptedTransport { request in
            let method = request["method"]?.string
            if method == "initialized" { return [] }
            let id = try #require(request["id"])
            if method == "initialize" { return [.reply(id, result: [:])] }
            #expect(method == "thread/read")
            return [.reply(id, result: ["thread": ["id": "elsewhere", "cwd": "/different"]])]
        }
        let client = CodexLiveClient(transport: transport, workspace: "/disposable")
        await #expect(throws: CodexLiveError.wrongWorkspace) {
            try await client.openSavedChat("elsewhere")
        }
        await client.close()
    }

    @Test func voiceUsesSubscriptionWebRTCRouteAndIgnoresOtherCalls() async throws {
        let transport = ScriptedTransport { request in
            let method = request["method"]?.string
            if method == "initialized" { return [] }
            let id = try #require(request["id"])
            let params = request["params"]
            switch method {
            case "initialize":
                #expect(params?["capabilities"]?["experimentalApi"] == .boolean(true))
                return [.reply(id, result: [:])]
            case "account/read":
                #expect(params?["refreshToken"] == .boolean(false))
                return [.reply(id, result: ["account": ["type": "chatgpt"]])]
            case "thread/start":
                #expect(params?["ephemeral"] == .boolean(true))
                #expect(params?["sandbox"] == "read-only")
                #expect(params?["environments"]?.array?.isEmpty == true)
                return [.reply(id, result: ["thread": ["id": "call", "cwd": "/disposable"]])]
            case "thread/realtime/start":
                #expect(params?["threadId"] == "call")
                #expect(params?["model"] == "gpt-live-1.1-codex")
                #expect(params?["version"] == "v3")
                #expect(params?["transport"]?["type"] == "webrtc")
                #expect(params?["transport"]?["sdp"] == "v=0\r\n")
                return [
                    .notification("thread/realtime/sdp", params: ["threadId": "unrelated", "sdp": "v=0 wrong"]),
                    .notification("thread/realtime/sdp", params: ["threadId": "call", "sdp": "v=0 answer"]),
                    .reply(id, result: [:])
                ]
            case "thread/realtime/stop":
                #expect(params?["threadId"] == "call")
                return [.reply(id, result: [:])]
            default:
                Issue.record("Unexpected voice RPC: \(method ?? "missing")")
                return [.failure(id, code: -32601, message: "Unexpected request")]
            }
        }
        let client = CodexLiveClient(transport: transport, workspace: "/disposable")
        let stream = try await client.startSubscriptionCall(offer: "v=0\r\n")
        var events = stream.makeAsyncIterator()
        #expect(try await events.next() == .answer("v=0 answer"))
        await client.endSubscriptionCall()
    }

    @Test func voiceDoesNotStartAThreadWithAPIKeyAuth() async throws {
        let transport = ScriptedTransport { request in
            let method = request["method"]?.string
            if method == "initialized" { return [] }
            let id = try #require(request["id"])
            switch method {
            case "initialize":
                return [.reply(id, result: [:])]
            case "account/read":
                return [.reply(id, result: ["account": ["type": "apiKey"]])]
            default:
                Issue.record("A voice call must stop before starting a thread on API-key auth.")
                return [.failure(id, code: -32601, message: "Unexpected request")]
            }
        }
        let client = CodexLiveClient(transport: transport, workspace: "/disposable")
        await #expect(throws: CodexLiveError.requiresChatGPTSignIn) {
            try await client.startSubscriptionCall(offer: "v=0\r\n")
        }
        await client.endSubscriptionCall()
    }

    @Test func directCodexWatchesAndSteersTheSameNativeTurn() async throws {
        let attachment = ChatAttachment(name: "notes.txt", data: Data("Fixture notes".utf8))
        let transport = ScriptedTransport { request in
            let method = request["method"]?.string
            if method == "initialized" { return [] }
            let id = try #require(request["id"])
            let params = request["params"]
            switch method {
            case "initialize":
                return [.reply(id, result: ["codexHome": "/test-codex-home"])]
            case "fs/createDirectory":
                return [.reply(id, result: [:])]
            case "fs/writeFile":
                #expect(params?["path"]?.string?.hasSuffix("/1-notes.txt") == true)
                #expect(params?["dataBase64"]?.string == attachment.data.base64EncodedString())
                return [.reply(id, result: [:])]
            case "thread/list":
                #expect(params?["cwd"] == "/disposable")
                return [.reply(id, result: ["data": .array([
                    ["id": "elsewhere", "cwd": "/elsewhere", "status": ["type": "active"]],
                    ["id": "live", "cwd": "/disposable", "status": ["type": "active"]]
                ])])]
            case "thread/resume":
                #expect(params?["threadId"] == "live")
                #expect(params?["excludeTurns"] == .boolean(true))
                return [.reply(id, result: ["thread": ["id": "live"], "model": "test-model"])]
            case "thread/turns/list":
                return [
                    .notification("item/commandExecution/outputDelta", params: [
                        "threadId": "elsewhere", "turnId": "running", "delta": "ignore"
                    ]),
                    .notification("item/commandExecution/outputDelta", params: [
                        "threadId": "live", "turnId": "running", "delta": "first live update"
                    ]),
                    .notification("turn/diff/updated", params: [
                        "threadId": "live", "turnId": "other-turn", "diff": "ignore"
                    ]),
                    .notification("turn/diff/updated", params: [
                        "threadId": "live", "turnId": "running", "diff": "-before\n+after"
                    ]),
                    .reply(id, result: ["data": .array([["id": "running", "status": "inProgress"]])])
                ]
            case "turn/steer":
                #expect(params?["threadId"] == "live")
                #expect(params?["expectedTurnId"] == "running")
                #expect(params?["input"]?.array?.first?["text"] == "change course")
                #expect(params?["input"]?.array?.last?["text"]?.string?.hasSuffix("/1-notes.txt") == true)
                return [
                    .reply(id, result: ["turnId": "running"]),
                    .notification("turn/completed", params: [
                        "threadId": "live", "turn": ["id": "running", "status": "completed"]
                    ])
                ]
            default:
                Issue.record("Unexpected native Codex method: \(method ?? "missing").")
                return [.failure(id, code: -32601, message: "Unexpected request.")]
            }
        }
        let client = CodexLiveClient(transport: transport, workspace: "/disposable")
        let turn = try await client.attach()
        #expect(turn.turnID == "running")
        var iterator = client.events.makeAsyncIterator()
        #expect(try await iterator.next() == .output(turnID: "running", text: "first live update"))
        #expect(try await iterator.next() == .diff(turnID: "running", patch: "-before\n+after"))
        #expect(try await client.steer("change course", expected: turn, attachments: [attachment]) == "running")
        #expect(try await iterator.next() == .completed(turnID: "running", status: "completed"))
        await #expect(throws: CodexLiveError.noActiveTurn) {
            try await client.steer("too late", expected: turn)
        }
        await client.close()
    }

    @Test func localCodexRefusesNonLoopbackEndpoints() {
        let settings = ["RIPTIDE_CODEX_WORKSPACE": "/disposable", "RIPTIDE_CODEX_BEARER": String(repeating: "a", count: 32)]
        for url in ["ws://192.0.2.1:49272", "ws://127.0.0.1.example.com:49272", "ws://127.0.0.1:49272/?credential=demo"] {
            #expect(CodexLocalEndpoint(environment: settings.merging(["RIPTIDE_CODEX_URL": url]) { _, new in new }) == nil)
        }
        #expect(CodexLocalEndpoint(environment: settings.merging(["RIPTIDE_CODEX_URL": "ws://127.0.0.1:49272"]) { _, new in new }) != nil)
    }

    @Test @MainActor func paginatedSessionsReopenWithTheirOwnWorkingDirectory() async throws {
        let transport = ScriptedTransport { request in
            let id = try #require(request["id"])
            switch request["method"]?.string {
            case "initialize":
                #expect(request["params"]?["protocolVersion"] == .integer(1))
                return [.reply(id, result: [
                    "protocolVersion": .integer(1),
                    "agentCapabilities": ["loadSession": .boolean(true), "sessionCapabilities": ["list": [:]]]
                ])]
            case "session/list" where request["params"]?["cursor"] == nil:
                return [.reply(id, result: [
                    "sessions": .array([["sessionId": "main", "title": "Main", "cwd": "/main"]]),
                    "nextCursor": "next"
                ])]
            case "session/list":
                #expect(request["params"]?["cursor"] == "next")
                return [.reply(id, result: [
                    "sessions": .array([["sessionId": "other", "title": "Design notes", "cwd": "/another-workspace"]])
                ])]
            case "session/load":
                #expect(request["params"]?["sessionId"] == "other")
                #expect(request["params"]?["cwd"] == "/another-workspace")
                return [.notification("session/update", params: [
                    "sessionId": "other",
                    "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Saved reply"]]
                ]), .reply(id, result: [:])]
            default:
                Issue.record("Unexpected request.")
                return [.failure(id, code: -32601, message: "Unexpected request.")]
            }
        }
        let target = AgentTarget(id: "target", name: "Demo", mainSessionID: "main", cwd: "/main")
        let model = AgentChatModel(target: target, client: ACPClient(transport: transport))
        await model.refreshSessions()
        #expect(model.sessions.map(\.id) == ["main", "other"])
        await model.open("other")
        #expect(model.title == "Design notes")
        #expect(model.selected.transcript.entries.map(\.content) == [.message(.assistant, "Saved reply")])
        #expect(model.selected.configOptions.isEmpty)
        #expect(model.selected.context == nil)
    }

    @Test @MainActor func chatShowsTheReportedModelBeforeTheChoicesAreAvailable() async {
        let transport = ScriptedTransport { request in
            let id = try #require(request["id"])
            switch request["method"]?.string {
            case "initialize":
                return [.reply(id, result: ["protocolVersion": .integer(1),
                                           "agentCapabilities": ["loadSession": .boolean(true)]])]
            case "session/load":
                return [.reply(id, result: [
                    "models": ["currentModelId": "openai-codex:gpt-6.2-sol", "availableModels": .array([])],
                    "configOptions": .array([
                        ["id": "model", "type": "select", "name": "Model", "category": "model",
                         "currentValue": "", "options": .array([])]
                    ])
                ])]
            case "session/new":
                return [.reply(id, result: [
                    "sessionId": "new",
                    "configOptions": .array([
                        ["id": "model", "type": "select", "name": "Model", "category": "model",
                         "currentValue": "openai-codex:gpt-6.1-sol-900k",
                         "options": .array([["value": "atlas", "name": "Atlas"]])]
                    ])
                ])]
            default:
                Issue.record("Unexpected ACP call")
                return []
            }
        }
        let target = AgentTarget(id: "target", name: "Demo", mainSessionID: "main", cwd: "/main")
        let client = ACPClient(transport: transport)
        let model = AgentChatModel(target: target, client: client)

        await model.showMain()
        #expect(model.selected.modelName == "6.2 Sol")
        #expect(!model.selected.hasConfigChoices)

        #expect(await model.createChat())
        #expect(model.selected.modelName == "6.1 Sol · 900K")
        #expect(model.selected.hasConfigChoices)

        await model.showMain()
        #expect(model.selected.modelName == "6.2 Sol")
        await client.close()
    }

    @Test @MainActor func hermesDelegatesOnlyIntoTheOpenChatAndKeepsTheReplyInHistory() async throws {
        let transport = ScriptedTransport { request in
            let id = try #require(request["id"])
            switch request["method"]?.string {
            case "initialize":
                return [.reply(id, result: ["protocolVersion": .integer(1),
                                           "agentCapabilities": ["loadSession": .boolean(true)]])]
            case "session/load":
                #expect(request["params"]?["sessionId"] == "existing")
                return [.reply(id, result: [:])]
            case "session/prompt":
                #expect(request["params"]?["sessionId"] == "existing")
                #expect(request["params"]?["prompt"]?.array?.first?["text"] == "Read the notes")
                return [("unrelated", "Do not speak this"), ("existing", "The notes "), ("existing", "are ready.")]
                    .map { session, body in
                        JSON.notification("session/update", params: ["sessionId": .string(session), "update": [
                            "sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string(body)]
                        ]])
                    } + [.reply(id, result: ["stopReason": "end_turn"])]
            default:
                Issue.record("Unexpected ACP call")
                return []
            }
        }
        let client = ACPClient(transport: transport)
        let model = AgentChatModel(target: AgentTarget(id: "target", name: "Hermes", mainSessionID: "existing", cwd: "/demo"),
                                   client: client)
        await model.showMain()
        await #expect(throws: ACPError.rejected("This chat is already working or no longer open.")) {
            try await model.submitHermesVoice("Wrong chat", in: "unrelated")
        }
        #expect(try await model.submitHermesVoice("Read the notes", in: "existing") == "The notes are ready.")
        let expected: [ChatEntry.Content] = [
            .message(.user, "Read the notes"), .message(.assistant, "The notes are ready.")
        ]
        let deadline = ContinuousClock.now + .seconds(2)
        while model.selected.transcript.entries.map(\.content) != expected && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.selected.transcript.entries.map(\.content) == expected)
        #expect(model.selected.transcript.entries.first?.receipt == .seen)
        await client.close()
    }

    @Test(arguments: [false, true])
    @MainActor func openClawNewChatNeedsTheHostToEchoTheNewAgentScopedKey(hasOpenedMain: Bool) async throws {
        for reportsFreshKey in [true, false] {
            let transport = ScriptedTransport { request in
                let id = try #require(request["id"])
                switch request["method"]?.string {
                case "initialize":
                    return [.reply(id, result: ["protocolVersion": .integer(1), "agentCapabilities": [
                        "loadSession": .boolean(true), "sessionCapabilities": ["list": [:]]
                    ]])]
                case "session/load":
                    return [.reply(id, result: [:])]
                case "session/list":
                    return [.reply(id, result: ["sessions": .array([
                        ["sessionId": "current", "cwd": "/demo", "_meta": ["sessionKey": "agent:ops:main"]]
                    ])])]
                case "session/new":
                    let key = try #require(request["params"]?["_meta"]?["sessionKey"]?.string)
                    #expect(key.hasPrefix("agent:ops:riptide-"))
                    return [.notification("session/update", params: ["sessionId": "new", "update": [
                        "sessionUpdate": "session_info_update",
                        "_meta": ["sessionKey": reportsFreshKey ? .string(key) : "agent:ops:main"]
                    ]]), .reply(id, result: ["sessionId": "new"])]
                default:
                    Issue.record("Unexpected ACP call")
                    return []
                }
            }
            let client = ACPClient(transport: transport)
            let model = AgentChatModel(target: AgentTarget(id: "target", name: "OpenClaw", mainSessionID: "current", cwd: "/demo"),
                                       connect: { client })
            if hasOpenedMain { await model.showMain() }
            #expect(await model.createChat(openClaw: true) == reportsFreshKey)
            if reportsFreshKey {
                #expect(model.selectedID == "new")
                let key = try await model.openClawVoiceSessionKey(for: "new")
                #expect(key.hasPrefix("agent:ops:riptide-"))
            } else {
                #expect(model.selectedID == "current")
            }
            await client.close()
        }
    }

    @Test @MainActor func createsAndKeepsAnUnlistedNewChatWithoutOpeningMain() async throws {
        let transport = ScriptedTransport { request in
            let id = try #require(request["id"])
            switch request["method"]?.string {
            case "initialize":
                return [.reply(id, result: ["protocolVersion": .integer(1), "agentCapabilities": [
                    "loadSession": .boolean(true), "sessionCapabilities": ["list": [:]]
                ]])]
            case "session/list":
                return [.reply(id, result: ["sessions": .array([
                    ["sessionId": "saved", "cwd": "/paired", "title": "Host-created chat"],
                    ["sessionId": "other", "cwd": "/elsewhere", "title": "Other workspace"]
                ])])]
            case "session/new":
                #expect(request["params"]?["cwd"] == "/paired")
                return [.reply(id, result: ["sessionId": "new"])]
            default:
                Issue.record("Unexpected ACP call")
                return []
            }
        }
        let target = AgentTarget(id: "target", name: "Hermes", mainSessionID: "main", cwd: "/paired")
        let model = AgentChatModel(target: target, connect: { ACPClient(transport: transport) })
        #expect(await model.createChat())
        #expect(model.selectedID == "new")
        #expect(model.selected.loaded)
        await model.refreshSessions()
        #expect(model.sessions.map(\.id) == ["saved", "new"])
    }

    @Test @MainActor func unavailableMainDoesNotSilentlyCreateAnotherSession() async {
        let transport = ScriptedTransport { request in
            let id = try #require(request["id"])
            guard request["method"] == "initialize" else {
                Issue.record("History is unsupported; no session RPC should be sent.")
                return [.failure(id, code: -32601, message: "Unexpected request.")]
            }
            return [.reply(id, result: ["protocolVersion": .integer(1), "agentCapabilities": [:]])]
        }
        let target = AgentTarget(id: "target", name: "Demo", mainSessionID: "main", cwd: "/main")
        let model = AgentChatModel(target: target, client: ACPClient(transport: transport))
        await model.showMain()
        #expect(model.selectedID == "main")
        #expect(!model.selected.loaded)
        #expect(model.selected.error == ACPError.historyUnavailable.errorDescription)
    }
}

private struct ScriptedTransport: ACPTransport {
    let incoming: AsyncThrowingStream<Data, any Error>
    private let output: AsyncThrowingStream<Data, any Error>.Continuation
    private let script: @Sendable (JSON) throws -> [JSON]

    init(script: @escaping @Sendable (JSON) throws -> [JSON]) {
        (incoming, output) = AsyncThrowingStream.makeStream()
        self.script = script
    }

    func send(_ message: Data) async throws {
        let request = try JSONDecoder().decode(JSON.self, from: message)
        for response in try script(request) {
            output.yield(try JSONEncoder().encode(response))
        }
    }
}
