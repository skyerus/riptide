import Foundation
import Testing
@testable import RiptideCore

@MainActor
struct ChatTests {
    private let target = AgentTarget.demos[0]

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

        #expect(await model.createChat())
        await model.answer(approval, optionID: "allow-once")
        #expect(model.selected.permissions.isEmpty)

        await model.showMain()
        #expect(model.selected.permissions == [approval])
        await model.answer(approval, optionID: "deny")
        try await waitUntil { model.selected.permissions.isEmpty && !model.selected.working }
        #expect(model.selected.transcript.entries.last?.content == .message(.assistant, "I skipped the sample action. Nothing was run."))
    }

    @Test func stopExpiresOutstandingApprovalsAndLeavesConversationUsable() async throws {
        let model = try makeModel()
        await model.showMain()
        model.submit("Request approval")
        try await waitUntil { !model.selected.permissions.isEmpty }
        await model.stop()
        try await waitUntil { model.selected.permissions.isEmpty && !model.selected.working }
        #expect(model.selected.notice == "Reply stopped.")

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

    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition() {
            guard clock.now < deadline else { throw ACPError.rejected("Fixture did not settle in time.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
