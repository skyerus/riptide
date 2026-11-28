import Foundation
import Synchronization
import Testing
@testable import RiptideCore

@MainActor
struct ChatTests {
    private let target = AgentTarget.demos[0]

    @Test func cachedHistoryAndRecentReplyAppearBeforeLiveResume() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChatHistoryCache(workspace: target.id, root: directory)
        let chat = target.mainSessionID
        let old = FastHistoryTransport.update("user_message_chunk", text: "Saved question")
        let checkpoint = try #require(ChatHistoryCheckpoint(wire: FastHistoryTransport.checkpoint(rows: 1, digit: "a")))
        cache.write(ChatHistorySnapshot(checkpoint: checkpoint, updates: [old]), chat: chat)
        let reply = "Newest reply\nThe full reply appeared before live attach."
        let transport = FastHistoryTransport(chat: chat, reply: reply)
        let model = AgentChatModel(target: target, historyCache: cache) { ACPClient(transport: transport) }
        model.preloadReplyPreview("Outdated reply", receivedAt: .distantPast, in: chat)
        #expect(!model.selected.hasDisplayHistory)
        model.preloadReplyPreview("Newest reply", receivedAt: .now, in: chat)
        #expect(model.selected.displayTranscript.entries.map(\.content) == [
            .message(.user, "Saved question"), .message(.assistant, "Newest reply")
        ])
        let cachedID = try #require(model.selected.displayTranscript.entries.first?.id)
        let replyID = try #require(model.selected.displayTranscript.entries.last?.id)
        let open = Task { await model.showMain() }

        try await waitUntil { await transport.awaitingBothRequests }
        #expect(model.selected.displayTranscript.entries.map(\.id) == [cachedID, replyID])
        #expect(!model.selected.loaded)
        #expect(model.selected.permissions.isEmpty)

        try await transport.sendPreview()
        try await waitUntil {
            model.selected.displayTranscript.entries.last?.content == .message(.assistant, reply)
        }
        #expect(model.selected.displayTranscript.entries.map(\.content) == [
            .message(.user, "Saved question"), .message(.user, "New question"), .message(.assistant, reply)
        ])
        let prefetchedIDs = model.selected.displayTranscript.entries.map(\.id)
        #expect(prefetchedIDs.first == cachedID)
        #expect(prefetchedIDs.last == replyID)
        #expect(!model.selected.loaded)

        try await transport.finishResume()
        await open.value
        #expect(model.selected.loaded)
        #expect(model.selected.displayTranscript.entries.map(\.content) == [
            .message(.user, "Saved question"), .message(.user, "New question"), .message(.assistant, reply)
        ])
        #expect(model.selected.displayTranscript.entries.map(\.id) == prefetchedIDs)
        try await waitUntil { model.selected.permissions.count == 1 }
        #expect(model.selected.permissions.first?.toolCallID == "clarify-still-pending")
        #expect(cache.read(chat)?.checkpoint.rows == 3)
        #expect(cache.read(chat)?.updates.count == 3)
        model.removeCachedHistory()
        #expect(cache.read(chat) == nil)
    }

    @Test func aFastResumeDisconnectRetriesWithRegularHistoryOnAFreshConnection() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChatHistoryCache(workspace: target.id, root: directory)
        let chat = target.mainSessionID
        let old = FastHistoryTransport.update("user_message_chunk", text: "Saved question")
        let checkpoint = try #require(ChatHistoryCheckpoint(wire: FastHistoryTransport.checkpoint(rows: 1, digit: "a")))
        cache.write(ChatHistorySnapshot(checkpoint: checkpoint, updates: [old]), chat: chat)
        let fast = FastHistoryTransport(chat: chat)
        let regular = GatedHistoryTransport(fixture: try FixtureTransport(target: target), mainID: chat)
        let clients = Mutex([ACPClient(transport: fast), ACPClient(transport: regular)])
        let model = AgentChatModel(target: target, historyCache: cache) {
            clients.withLock { $0.removeFirst() }
        }
        let open = Task { await model.showMain() }

        try await waitUntil { await fast.awaitingBothRequests }
        try await fast.sendPreview()
        try await waitUntil { model.selected.displayTranscript.entries.last?.content == .message(.assistant, "Newest reply") }
        #expect(model.enqueue("Send after the connection is back", in: chat))
        await fast.disconnect()

        try await waitUntil { await regular.mainLoads == 1 }
        #expect(model.selected.loading)
        #expect(model.selected.error == nil)
        #expect(model.selected.displayTranscript.entries.last?.content == .message(.assistant, "Newest reply"))
        #expect(model.selected.queuedMessages.map(\.text) == ["Send after the connection is back"])
        #expect(await regular.promptSessions.isEmpty)
        await regular.releaseHistory()
        await open.value
        try await waitUntil { await regular.promptSessions == [chat] }
        try await waitUntil { model.selected.queuedMessages.isEmpty }
        #expect(model.selected.loaded)
        #expect(model.selected.error == nil)
        #expect(clients.withLock { $0.isEmpty })
    }

    @Test func sendWhileOpeningASideChatKeepsItsDestinationAfterSwitchingAway() async throws {
        let side = "\(target.id)-sample-1"
        let fixture = try FixtureTransport(target: target, catalog: ["Saved side chat"])
        let transport = GatedHistoryTransport(fixture: fixture, mainID: side)
        let model = AgentChatModel(target: target) { ACPClient(transport: transport) }
        await model.showMain()
        await model.refreshSessions()
        model.prepareToOpen(side)
        try await waitUntil { await transport.mainLoads == 1 }
        #expect(model.selectedID == target.mainSessionID)

        let viewOpening = Task { await model.open(side) }
        try await waitUntil { model.canQueueWhileConnecting(in: side) }
        #expect(model.enqueue("Send to the side chat", in: side))
        #expect(await transport.promptSessions.isEmpty)

        viewOpening.cancel()
        await model.showMain()
        await transport.releaseHistory()
        await viewOpening.value
        try await waitUntil { await transport.promptSessions == [side] }
        #expect(model.selectedID == target.mainSessionID)
        #expect(!model.selected.transcript.entries.contains { $0.content == .message(.user, "Send to the side chat") })

        await model.open(side)
        try await waitUntil { model.selected.queuedMessages.isEmpty }
        #expect(model.selected.transcript.entries.filter { $0.content == .message(.user, "Send to the side chat") }.count == 1)
        #expect(await transport.mainLoads == 1)
    }

    @Test func aFailedQueuedWritePausesTheFollowingMessages() async throws {
        let chat = target.mainSessionID
        let transport = GatedHistoryTransport(fixture: try FixtureTransport(target: target), mainID: chat)
        await transport.failNextPrompt()
        let model = AgentChatModel(target: target) { ACPClient(transport: transport) }
        let open = Task { await model.showMain() }
        try await waitUntil { model.canQueueWhileConnecting(in: chat) }
        #expect(model.enqueue("First queued message", in: chat))
        #expect(model.enqueue("Next queued message", in: chat))

        await transport.releaseHistory()
        await open.value
        try await waitUntil { model.selected.queuePaused }
        #expect(model.selected.queuedMessages.map(\.text) == ["First queued message", "Next queued message"])
        #expect(await transport.promptSessions == [chat])
    }

    @Test func steeringAndQueuedFollowUpsStayWithTheirOriginalChat() async throws {
        let model = try makeModel()
        await model.showMain()
        let main = model.selectedID
        #expect(model.submit("Show an approval"))
        try await waitUntil { !model.selected.permissions.isEmpty }
        #expect(await model.steer("Focus on the draft", in: main))
        #expect(model.selected.transcript.entries.contains { $0.content == .message(.user, "Focus on the draft") })
        #expect(model.enqueue("Follow up separately", in: main))
        #expect(model.enqueue("Remove this follow-up", in: main))
        let discarded = try #require(model.selected.queuedMessages.last)
        model.removeQueuedMessage(discarded.id, in: main)
        #expect(model.selected.queuedMessages.map(\.text) == ["Follow up separately"])
        #expect(!model.selected.transcript.entries.contains { $0.content == .message(.user, "Follow up separately") })
        let permission = try #require(model.selected.permissions.first)
        await model.answer(permission, optionID: nil)
        #expect(await model.createChat())
        try await waitUntil { !model.workingChats.contains(main) }
        #expect(model.selected.transcript.entries.isEmpty)
        await model.showMain()
        #expect(model.selected.queuedMessages.isEmpty)
        let sent = model.selected.transcript.entries.compactMap { entry in
            if case .message(.user, let text) = entry.content { return text }
            return nil
        }
        #expect(sent == ["Show an approval", "Focus on the draft", "Follow up separately"])
    }

    @Test func attachmentOnlyFollowUpWaitsForTheOriginalReply() async throws {
        let model = try makeModel()
        await model.showMain()
        let main = model.selectedID
        #expect(model.submit("Show an approval"))
        try await waitUntil { !model.selected.permissions.isEmpty }

        let report = ChatAttachment(name: "Report.pdf", data: Data("%PDF-1.4".utf8))
        #expect(model.enqueue("", attachments: [report], in: main))
        #expect(model.selected.queuedMessages.first?.attachments == [report])
        #expect(!model.selected.transcript.entries.contains { $0.content == .message(.user, "Attached: Report.pdf") })

        let permission = try #require(model.selected.permissions.first)
        await model.answer(permission, optionID: nil)
        try await waitUntil { !model.selected.working && model.selected.queuedMessages.isEmpty }
        #expect(model.selected.transcript.entries.contains { $0.content == .message(.user, "Attached: Report.pdf") })
    }

    @Test func timedOutReplyKeepsUncertainFollowUpForExplicitContinuation() async throws {
        let transport = try FixtureTransport(target: target, pace: .milliseconds(5), timeoutOnSteer: true)
        let model = AgentChatModel(target: target, client: ACPClient(transport: transport))
        await model.showMain()
        let main = model.selectedID
        #expect(model.submit("Show an approval"))
        try await waitUntil { !model.selected.permissions.isEmpty }

        #expect(!(await model.steer("Check the existing integration", in: main)))
        try await waitUntil { model.selected.replyTimedOut && !model.selected.working }
        #expect(model.selected.uncertainFollowUp == "Check the existing integration")
        #expect(model.selected.transcript.entries.filter(\.isConversationMessage).count == 2)
        #expect(model.completedReplies[main] == nil)

        #expect(model.continueAfterTimeout(in: main))
        #expect(!model.continueAfterTimeout(in: main))
        #expect(model.selected.transcript.entries.contains { entry in
            guard case .message(.user, let text) = entry.content else { return false }
            return text.contains("verify what already happened") && text.hasSuffix("Check the existing integration")
        })
    }

    @Test func confirmedUndeliveredSteerStartsExactlyOnceAfterObservedTimeout() async throws {
        let main = target.mainSessionID
        let transport = TurnActivityTransport(sessionID: main, reopened: true, supportsSteering: true)
        let model = AgentChatModel(target: target, client: ACPClient(transport: transport))
        await model.showMain()
        await transport.expireSteeringTarget(confirmedUndelivered: true)
        #expect(model.enqueue("An explicitly queued message", in: main))
        #expect(await model.steer("Check the existing integration", in: main))
        #expect(await transport.promptCount == 0)

        try await transport.timeout()
        try await waitUntil { await transport.promptCount == 1 }
        #expect(model.selected.queuedMessages.map(\.text) == ["An explicitly queued message"])
        #expect(model.selected.queuePaused)
        #expect(model.selected.transcript.entries.filter {
            $0.content == .message(.user, "Check the existing integration")
        }.count == 1)
    }

    @Test func openingMainJoinsAnInFlightPreloadWithoutChangingTheCurrentChatEarly() async throws {
        let fixture = try FixtureTransport(target: target, catalog: ["Side chat"])
        let transport = GatedHistoryTransport(fixture: fixture, mainID: target.mainSessionID)
        let model = AgentChatModel(target: target, client: ACPClient(transport: transport))
        await model.refreshSessions()
        let side = try #require(model.sessions.first { $0.id != target.mainSessionID })
        await model.open(side.id)

        let preload = Task { await model.preloadMain() }
        defer { Task { await transport.releaseHistory() } }
        try await waitUntil { await transport.mainLoads == 1 }
        #expect(model.selectedID == side.id)

        let open = Task {
            await model.showMain()
            #expect(model.selected.loaded)
        }
        try await waitUntil { model.selectedID == target.mainSessionID }
        #expect(model.selected.loading)
        #expect(model.selected.transcript.entries.isEmpty)

        await transport.releaseHistory()
        await open.value
        await preload.value
        await model.showMain()
        #expect(await transport.mainLoads == 1)
        #expect(model.selected.transcript.entries.count == 1)
    }

    @Test func mainStaysTheDefaultWhileSavedSideChatsReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let file = directory.appending(path: "fixture.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try makeModel(file: file)

        await model.showMain()
        #expect(model.selectedID == target.mainSessionID)
        #expect(model.selected.transcript.entries.count == 1)
        #expect(await model.createChat())
        let sideID = model.selectedID
        #expect(sideID != target.mainSessionID)
        #expect(model.selected.transcript.entries.isEmpty)
        model.submit("A separate conversation")

        await model.showMain()
        #expect(model.selected.transcript.entries.count == 1)
        await model.open(sideID)
        try await waitUntil { !model.selected.working && model.selected.transcript.entries.count == 3 }

        let reopened = try makeModel(file: file)
        await reopened.showMain()
        #expect(reopened.selectedID == target.mainSessionID)
        #expect(reopened.selected.transcript.entries.count == 1)
        await reopened.refreshSessions()
        #expect(reopened.sessions.contains { $0.id == sideID && $0.title == "A separate conversation" })
        await reopened.open(sideID)
        await reopened.showMain()
        await reopened.open(sideID)
        #expect(reopened.selected.transcript.entries.count == 3)
        #expect(reopened.selected.transcript.entries.first?.receipt == .seen)
        #expect(reopened.selected.transcript.visibleEntries(showCompletedToolCalls: false).count == 2)
        let contents = reopened.selected.transcript.entries.map(\.content)
        #expect(contents.first == .message(.user, "A separate conversation"))
        guard case .tool(let tool) = contents[1], case .message(.assistant, let reply) = contents[2] else {
            Issue.record("Expected tool and streamed response.")
            return
        }
        #expect(tool.status == "completed")
        #expect(reply.contains("| Area | Status |\n| --- | --- |"))
        #expect(model.completedReplies[sideID]?.preview == WorkspaceAttention.preview(reply))
    }

    @Test func coldSavedChatUsesOneConnectionForLookupAndHistory() async throws {
        let target = AgentTarget.demos[1]
        let fixture = try FixtureTransport(target: target, catalog: ["Saved Hermes chat"])
        let spare = try FixtureTransport(target: target, catalog: ["Saved Hermes chat"])
        let clients = Mutex([ACPClient(transport: fixture), ACPClient(transport: spare)])
        let model = AgentChatModel(target: target, connect: { clients.withLock { $0.removeFirst() } })
        let chatID = "\(target.id)-sample-1"

        #expect(await model.openSavedChat(chatID))
        #expect(model.selected.loaded)
        #expect(model.selected.transcript.entries.map(\.content) == [.message(.assistant, "Fixture chat: Saved Hermes chat")])
        #expect(clients.withLock { $0.count } == 1)
        #expect(!(await model.openSavedChat("missing-chat")))
        #expect(model.selectedID == chatID)
        #expect(clients.withLock { $0.count } == 1)
    }

    @Test func warmChatStaysOpenUntilIdleAndThenRestoresFromOneNewConnection() async throws {
        let first = try FixtureTransport(target: target)
        let second = try FixtureTransport(target: target)
        let clients = Mutex([ACPClient(transport: first), ACPClient(transport: second)])
        let model = AgentChatModel(target: target, idleTimeout: .milliseconds(80),
                                   connect: { clients.withLock { $0.removeFirst() } })
        model.setConnectionInUse(true)
        await model.showMain()
        let transcript = model.selected.transcript.entries.map(\.content)

        try await Task.sleep(for: .milliseconds(120))
        #expect(model.selected.loaded)
        model.setConnectionInUse(false)
        await model.showMain()
        #expect(model.selected.loaded)
        #expect(clients.withLock { $0.count } == 1)

        try await waitUntil { model.selected.connectionLost }
        #expect(model.selected.error == nil)
        #expect(model.selected.transcript.entries.map(\.content) == transcript)
        #expect(clients.withLock { $0.count } == 1)

        model.setConnectionInUse(true)
        await model.showMain()
        #expect(model.selected.loaded)
        #expect(model.selected.transcript.entries.map(\.content) == transcript)
        #expect(clients.withLock { $0.isEmpty })
    }

    @Test func reopeningAfterDisconnectReplaysTheReplyWithoutSendingThePromptAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let file = directory.appending(path: "fixture.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = self.target
        let transport = try FixtureTransport(target: target, file: file, pace: .milliseconds(40))
        let first = ACPClient(transport: transport)
        let model = AgentChatModel(target: target, connect: {
            guard FileManager.default.fileExists(atPath: file.path),
                  let replay = try? FixtureTransport(target: target, file: file) else { return first }
            return ACPClient(transport: replay)
        })

        await model.showMain()
        model.submit("An acknowledged message")
        try await waitUntil { model.selected.transcript.entries.contains { $0.receipt == .seen } }
        await first.close()
        try await waitUntil { model.selected.connectionLost }
        #expect(!model.selected.loaded)
        #expect(!model.selected.working)
        #expect(model.selected.transcript.entries.contains { $0.receipt == .seen })

        try await waitUntil {
            (try? String(contentsOf: file, encoding: .utf8))?
                .contains("You can come back to this conversation whenever you need it.") == true
        }
        await model.open(target.mainSessionID)
        #expect(model.selected.loaded)
        #expect(!model.selected.connectionLost)
        #expect(model.selected.error == nil)
        let sent = model.selected.transcript.entries.filter { $0.content == .message(.user, "An acknowledged message") }
        #expect(sent.map(\.receipt) == [.seen])
        #expect(model.selected.transcript.latestAssistantEntryID != nil)
    }

    @Test(arguments: [false, true])
    func restoredProgressIsVisibleOnlyWhileTheTurnIsActive(completesDuringLoad: Bool) async throws {
        let target = AgentTarget.demos[1]
        let transport = TurnActivityTransport(sessionID: target.mainSessionID, reopened: true,
                                              loadProgress: completesDuringLoad ? .completed : .working)
        let model = AgentChatModel(target: target, client: ACPClient(transport: transport))
        await model.showMain()
        let progress = ChatEntry.Content.message(.assistant, "Checking the current changes.")
        let final = ChatEntry.Content.message(.assistant, "The review is ready.")
        if completesDuringLoad {
            #expect(!model.selected.working)
            let messages = model.selected.transcript.visibleEntries(showCompletedToolCalls: false).map(\.content)
            #expect(!messages.contains(progress))
            #expect(messages.contains(final))
        } else {
            #expect(model.selected.working)
            #expect(model.selected.transcript.visibleEntries(showCompletedToolCalls: false).contains { $0.content == progress })
            try await transport.complete()
            try await waitUntil { !model.selected.working }
            let messages = model.selected.transcript.visibleEntries(showCompletedToolCalls: false).map(\.content)
            #expect(!messages.contains(progress))
            #expect(messages.contains(final))
        }
        #expect(await transport.promptCount == 0)
    }

    @Test(arguments: [false, true], [false, true])
    func reconnectRestoresAnActiveHermesTurnWithoutResubmitting(supportsSteering: Bool, queueFollowUp: Bool) async throws {
        let target = AgentTarget.demos[1]
        let initial = TurnActivityTransport(sessionID: target.mainSessionID, reopened: false)
        let resumed = TurnActivityTransport(sessionID: target.mainSessionID, reopened: true, supportsSteering: supportsSteering)
        let first = ACPClient(transport: initial)
        let second = ACPClient(transport: resumed)
        let clients = Mutex([first, second])
        let model = AgentChatModel(target: target, connect: { clients.withLock { $0.removeFirst() } })

        await model.showMain()
        model.submit("Review the project")
        try await waitUntil { await initial.promptCount == 1 }
        #expect(model.selected.canStop)
        #expect(model.selected.turnStartedAt != nil)
        await first.close()
        try await waitUntil { model.selected.connectionLost }
        #expect(!model.selected.working)
        #expect(model.selected.turnStartedAt == nil)

        await model.showMain()
        #expect(!model.selected.connectionLost)
        #expect(model.selected.working)
        let resumedStart = try #require(model.selected.turnStartedAt)
        #expect(!model.selected.canStop)
        #expect(model.selected.canSteer == supportsSteering)
        #expect(model.workingChats == [target.mainSessionID])
        #expect(model.selected.transcript.entries.map(\.content) == [.message(.user, "Review the project")])
        #expect(!model.submit("Do not send a second message"))
        if supportsSteering {
            #expect(await model.steer("Focus on the draft", in: target.mainSessionID))
            #expect(await resumed.steers == ["Focus on the draft"])
            #expect(model.selected.turnStartedAt == resumedStart)
            #expect(model.selected.transcript.entries.last?.content == .message(.user, "Focus on the draft"))
            #expect(model.selected.queuedMessages.isEmpty)
            await resumed.expireSteeringTarget()
            #expect(!(await model.steer("Keep this draft", in: target.mainSessionID)))
            #expect(model.selected.steeringError != nil)
        } else {
            #expect(!(await model.steer("Do not steer this turn", in: target.mainSessionID)))
            #expect(await resumed.steers.isEmpty)
        }
        if queueFollowUp {
            #expect(model.enqueue("Queued follow-up", in: target.mainSessionID))
            #expect(model.selected.queuedMessages.map(\.text) == ["Queued follow-up"])
        }
        await model.stop()
        #expect(await resumed.promptCount == 0)
        #expect(await resumed.cancelCount == 0)

        try await resumed.reportTool()
        try await waitUntil { model.selected.transcript.activeToolCalls.first?.title == "Review context" }
        try await resumed.complete()
        if queueFollowUp {
            try await waitUntil { await resumed.promptCount == 1 }
            #expect(model.selected.queuedMessages.isEmpty)
            #expect(model.selected.transcript.entries.suffix(2).map(\.content) == [
                .message(.assistant, "The review is ready."), .message(.user, "Queued follow-up")
            ])
        } else {
            try await waitUntil { !model.selected.working }
            #expect(model.selected.turnStartedAt == nil)
            #expect(!model.selected.canSteer)
            #expect(model.workingChats.isEmpty)
            #expect(model.selected.transcript.entries.last?.content == .message(.assistant, "The review is ready."))
        }
        await second.close()
    }

    @Test func canDenyPermissionAndOnlyUpdatesItsOriginalConversation() async throws {
        let model = try makeModel()
        await model.showMain()
        model.submit("Show an approval")
        try await waitUntil { !model.selected.permissions.isEmpty }
        let approval = try #require(model.selected.permissions.first)
        let liveTranscript = model.selected.transcript
        #expect(liveTranscript.entries.first(where: { $0.receipt != nil })?.receipt == .seen)
        #expect(liveTranscript.activeToolCalls.map(\.title) == ["Review context"])
        #expect(liveTranscript.visibleEntries(showCompletedToolCalls: true).count == liveTranscript.entries.count - 1)

        #expect(await model.createChat())
        await model.answer(approval, optionID: "allow-once")
        #expect(model.selected.permissions.isEmpty)

        await model.showMain()
        #expect(model.selected.permissions == [approval])
        await model.answer(approval, optionID: "deny")
        try await waitUntil { model.selected.permissions.isEmpty && !model.selected.working }
        #expect(model.selected.transcript.entries.last?.content == .message(.assistant, "I skipped the sample action. Nothing was run."))
        #expect(model.selected.transcript.entries.first(where: { $0.receipt != nil })?.receipt == .seen)
        #expect(model.selected.transcript.hasCompletedToolCalls)
        #expect(model.selected.transcript.activeToolCalls.isEmpty)
        #expect(model.selected.transcript.visibleEntries(showCompletedToolCalls: false).count ==
                model.selected.transcript.entries.count - 1)
    }

    @Test func stopExpiresOutstandingApprovalsAndLeavesConversationUsable() async throws {
        let model = try makeModel()
        await model.showMain()
        model.submit("Request approval")
        try await waitUntil { !model.selected.permissions.isEmpty }
        await model.stop()
        try await waitUntil { model.selected.permissions.isEmpty && !model.selected.working }
        #expect(model.selected.notice == "Reply stopped.")
        #expect(model.selected.transcript.entries.first(where: { $0.receipt != nil })?.receipt == .seen)

        model.submit("Try the fixture again")
        try await waitUntil { !model.selected.working && model.selected.transcript.entries.count >= 6 }
        #expect(model.selected.error == nil)
    }

    @Test func explicitMessageIDKeepsChunksTogetherThroughToolUpdates() {
        var transcript = Transcript()
        transcript.apply(.message(sessionID: "demo", messageID: "reply", role: .assistant, text: "one "))
        transcript.apply(.tool(sessionID: "demo", activity: ToolActivity(id: "tool", title: "Example", status: "pending")))
        transcript.apply(.message(sessionID: "demo", messageID: "reply", role: .assistant, text: "two"))
        transcript.apply(.tool(sessionID: "demo", activity: ToolActivity(id: "tool", title: nil, status: "completed")))
        #expect(transcript.entries.map(\.content) == [
            .message(.assistant, "one two"),
            .tool(ToolActivity(id: "tool", title: "Example", status: "completed"))
        ])
    }

    @Test func agentActivityMarksTheMessageSeenBeforeAReply() {
        var transcript = Transcript()
        transcript.apply(.message(sessionID: "demo", messageID: "prompt", role: .user, text: "Take a look"))
        #expect(transcript.entries.first?.receipt == .delivered)
        transcript.apply(.agentActivity(sessionID: "demo"))
        #expect(transcript.entries.first?.receipt == .seen)
        #expect(transcript.entries.count == 1)
    }

    @Test func composerControlsAreBackendOwnedAndPersistPerChat() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let file = directory.appending(path: "fixture.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try makeModel(file: file)
        let mainID = target.mainSessionID
        await model.showMain()
        #expect(model.selected.configOptions.first { $0.category == .model }?.currentName == "Atlas")
        #expect(model.selected.context?.capacity == 128_000)

        await model.setConfigOption("effort", value: "high", sessionID: mainID)
        #expect(model.selected.configOptions.first { $0.category == .thoughtLevel }?.currentName == "High")
        await model.setConfigOption("model", value: "atlas-mini", sessionID: mainID)
        try await waitUntil { model.selected.context?.capacity == 64_000 }
        #expect(model.selected.configOptions.first { $0.category == .thoughtLevel }?.currentName == "Medium")
        #expect(model.selected.configOptions.first { $0.category == .thoughtLevel }?.choices.count == 2)

        #expect(await model.createChat())
        try await waitUntil { model.selected.context?.capacity == 128_000 }
        #expect(model.selected.configOptions.first { $0.category == .model }?.currentName == "Atlas")
        await model.setConfigOption("model", value: "atlas", sessionID: mainID)

        let reopened = try makeModel(file: file)
        await reopened.showMain()
        #expect(reopened.selected.configOptions.first { $0.category == .model }?.currentName == "Atlas Mini")
        #expect(reopened.selected.context?.capacity == 64_000)
    }

    private func makeModel(file: URL? = nil) throws -> AgentChatModel {
        let transport = try FixtureTransport(target: target, file: file, pace: .milliseconds(12))
        return AgentChatModel(target: target, client: ACPClient(transport: transport))
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !(await condition()) {
            guard clock.now < deadline else { throw ACPError.rejected("Fixture did not settle in time.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor FastHistoryTransport: ACPTransport {
    nonisolated let incoming: AsyncThrowingStream<Data, any Error>
    private let output: AsyncThrowingStream<Data, any Error>.Continuation
    private let chat: String
    private let reply: String
    private var previewID: JSON?
    private var resumeID: JSON?

    init(chat: String, reply: String = "Newest reply") {
        self.chat = chat
        self.reply = reply
        (incoming, output) = AsyncThrowingStream.makeStream()
    }

    var awaitingBothRequests: Bool { previewID != nil && resumeID != nil }

    func send(_ data: Data) throws {
        let request = try JSONDecoder().decode(JSON.self, from: data)
        let id = try #require(request["id"])
        switch request["method"]?.string {
        case "initialize":
            try emit(.reply(id, result: ["protocolVersion": .integer(1), "agentCapabilities": [
                "loadSession": .boolean(true), "_meta": ["app.riptide.fastResume": .integer(1)]
            ]]))
        case "_riptide/session/recent":
            previewID = id
        case "_riptide/session/resume":
            #expect(request["params"]?["checkpoint"] == Self.checkpoint(rows: 1, digit: "a"))
            resumeID = id
        default:
            Issue.record("Unexpected request \(request)")
        }
    }

    func sendPreview() throws {
        try emit(.reply(try #require(previewID), result: [
            "updates": .array([
                Self.update("user_message_chunk", text: "Saved question"),
                Self.update("user_message_chunk", text: "New question"),
                Self.update("agent_message_chunk", text: reply)
            ])
        ]))
    }

    func disconnect() { output.finish() }

    func finishResume() throws {
        for update in [Self.update("user_message_chunk", text: "New question"),
                       Self.update("agent_message_chunk", text: reply)] {
            try emit(.notification("_riptide/session/history", params: ["sessionId": .string(chat), "update": update]))
        }
        try emit(.request("session/request_permission", id: "handback", params: [
            "sessionId": .string(chat),
            "toolCall": ["toolCallId": "clarify-still-pending", "title": "Complete sign-in"],
            "options": .array([["optionId": "choice-0", "name": "Browser handoff complete", "kind": "allow_once"],
                               ["optionId": "skip", "name": "Skip", "kind": "reject_once"]])
        ]))
        try emit(.reply(try #require(resumeID), result: ["checkpoint": Self.checkpoint(rows: 3, digit: "b"), "reuseHistory": .boolean(true)]))
    }

    static func checkpoint(rows: Int, digit: String) -> JSON {
        ["rows": .integer(rows), "digest": .string(String(repeating: digit, count: 64))]
    }

    static func update(_ kind: String, text: String) -> JSON {
        ["sessionUpdate": .string(kind), "messageId": .string(text), "content": ["type": "text", "text": .string(text)]]
    }

    private func emit(_ message: JSON) throws { output.yield(try JSONEncoder().encode(message)) }
}

private actor GatedHistoryTransport: ACPTransport {
    nonisolated var incoming: AsyncThrowingStream<Data, any Error> { fixture.incoming }
    private let fixture: FixtureTransport
    private let mainID: String
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var failPrompt = false
    private(set) var mainLoads = 0
    private(set) var promptSessions: [String] = []

    init(fixture: FixtureTransport, mainID: String) {
        self.fixture = fixture
        self.mainID = mainID
    }

    func send(_ message: Data) async throws {
        let request = try JSONDecoder().decode(JSON.self, from: message)
        if request["method"] == "session/load", request["params"]?["sessionId"]?.string == mainID {
            mainLoads += 1
            if !released { await withCheckedContinuation { waiting.append($0) } }
        }
        if request["method"] == "session/prompt", let id = request["params"]?["sessionId"]?.string {
            promptSessions.append(id)
            if failPrompt {
                failPrompt = false
                throw ACPError.disconnected
            }
        }
        try await fixture.send(message)
    }

    func failNextPrompt() { failPrompt = true }

    func releaseHistory() {
        released = true
        for task in waiting { task.resume() }
        waiting.removeAll()
    }
}

private actor TurnActivityTransport: ACPTransport {
    enum LoadProgress { case working, completed }

    nonisolated let incoming: AsyncThrowingStream<Data, any Error>
    private let output: AsyncThrowingStream<Data, any Error>.Continuation
    private let sessionID: String
    private let reopened: Bool
    private let supportsSteering: Bool
    private let loadProgress: LoadProgress?
    private var rejectsSteer = false
    private var confirmsSteerRejection = false
    private(set) var promptCount = 0
    private(set) var cancelCount = 0
    private(set) var steers: [String] = []

    init(sessionID: String, reopened: Bool, supportsSteering: Bool = false, loadProgress: LoadProgress? = nil) {
        (incoming, output) = AsyncThrowingStream.makeStream()
        self.sessionID = sessionID
        self.reopened = reopened
        self.supportsSteering = supportsSteering
        self.loadProgress = loadProgress
    }

    func send(_ data: Data) async throws {
        let packet = try JSONDecoder().decode(JSON.self, from: data)
        let id = packet["id"] ?? .null
        switch packet["method"]?.string {
        case "initialize":
            try emit(.reply(id, result: [
                "protocolVersion": .integer(1), "agentCapabilities": ["loadSession": .boolean(true)]
            ]))
        case "session/load":
            if reopened {
                try update(["sessionUpdate": "user_message_chunk", "messageId": "prompt",
                            "content": ["type": "text", "text": "Review the project"]])
                try reportActivity(true)
                if let loadProgress {
                    try update(["sessionUpdate": "agent_message_chunk", "messageId": "progress",
                                "content": ["type": "text", "text": "Checking the current changes."],
                                "_meta": ["app.riptide.assistantProgress": .boolean(true)]])
                    if loadProgress == .completed { try complete() }
                }
            }
            try emit(.reply(id, result: [:]))
        case "session/prompt":
            promptCount += 1
            try reportActivity(true)
        case "session/cancel":
            cancelCount += 1
        case "_riptide/session/steer":
            if supportsSteering, !rejectsSteer, packet["params"]?["admissionId"] == "active-reply",
               let text = packet["params"]?["text"]?.string {
                steers.append(text)
                try emit(.reply(id, result: ["status": "steered"]))
            } else {
                var result: [String: JSON] = ["status": "idle"]
                if confirmsSteerRejection { result["delivered"] = .boolean(false) }
                try emit(.reply(id, result: .object(result)))
            }
        default:
            break
        }
    }

    func expireSteeringTarget(confirmedUndelivered: Bool = false) {
        rejectsSteer = true
        confirmsSteerRejection = confirmedUndelivered
    }

    func timeout() throws {
        try update(["sessionUpdate": "session_info_update", "_meta": ["app.riptide.turnFailure": "timeout"]])
        try reportActivity(false)
    }

    func reportTool() throws {
        try update(["sessionUpdate": "tool_call", "toolCallId": "tool",
                    "title": "Review context", "status": "in_progress"])
    }

    func complete() throws {
        try update(["sessionUpdate": "tool_call_update", "toolCallId": "tool", "status": "completed"])
        try update(["sessionUpdate": "agent_message_chunk", "messageId": "reply",
                    "content": ["type": "text", "text": "The review is ready."]])
        try reportActivity(false)
    }

    private func reportActivity(_ working: Bool) throws {
        var metadata: [String: JSON] = ["app.riptide.turnWorking": .boolean(working)]
        if working, supportsSteering { metadata["app.riptide.steerAdmissionId"] = "active-reply" }
        try update(["sessionUpdate": "session_info_update", "_meta": .object(metadata)])
    }

    private func update(_ update: JSON) throws {
        try emit(.notification("session/update", params: ["sessionId": .string(sessionID), "update": update]))
    }

    private func emit(_ packet: JSON) throws {
        output.yield(try JSONEncoder().encode(packet))
    }
}
