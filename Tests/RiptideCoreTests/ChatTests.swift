import Foundation
import Testing
@testable import RiptideCore

@MainActor
struct ChatTests {
    private let target = AgentTarget.demos[0]

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
    }

    @Test func canDenyPermissionAndOnlyUpdatesItsOriginalConversation() async throws {
        let model = try makeModel()
        await model.showMain()
        model.submit("Show an approval")
        try await waitUntil { !model.selected.permissions.isEmpty }
        let approval = try #require(model.selected.permissions.first)
        let liveTranscript = model.selected.transcript
        #expect(liveTranscript.entries.first(where: { $0.receipt != nil })?.receipt == .delivered)
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
        #expect(model.selected.transcript.entries.first(where: { $0.receipt != nil })?.receipt == .delivered)

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

private actor GatedHistoryTransport: ACPTransport {
    nonisolated var incoming: AsyncThrowingStream<Data, any Error> { fixture.incoming }
    private let fixture: FixtureTransport
    private let mainID: String
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var mainLoads = 0

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
        try await fixture.send(message)
    }

    func releaseHistory() {
        released = true
        for task in waiting { task.resume() }
        waiting.removeAll()
    }
}
