import Foundation
import Testing
@testable import RiptideCore

struct WorkspaceExperienceTests {
    @Test func growingAReplyDoesNotOverrideTheReadersScrollIntent() {
        var follow = TranscriptFollow()
        follow.geometryChanged(nearBottom: false)
        #expect(follow.canScrollAutomatically)
        follow.phaseChanged(.scrolling, nearBottom: true)
        #expect(!follow.canScrollAutomatically)
        follow.geometryChanged(nearBottom: false)
        follow.phaseChanged(.idle, nearBottom: false)
        #expect(!follow.following)
        follow.geometryChanged(nearBottom: true)
        #expect(!follow.following)
        follow.jumpToLatest()
        #expect(follow.canScrollAutomatically)
    }

    @Test func holdingTheTranscriptPausesUntilReleaseWithoutChangingReadingIntent() {
        var live = TranscriptFollow()
        live.phaseChanged(.touching, nearBottom: true)
        #expect(!live.canScrollAutomatically)
        live.geometryChanged(nearBottom: false)
        live.phaseChanged(.idle, nearBottom: false)
        #expect(live.canScrollAutomatically)

        var reading = TranscriptFollow(following: false)
        reading.phaseChanged(.touching, nearBottom: false)
        reading.phaseChanged(.idle, nearBottom: false)
        #expect(!reading.canScrollAutomatically)
        reading.phaseChanged(.scrolling, nearBottom: true)
        #expect(!reading.canScrollAutomatically)
        reading.phaseChanged(.idle, nearBottom: true)
        #expect(reading.canScrollAutomatically)
    }

    @Test func searchCanCombineWorkspaceAndChatTermsAndPrefersExactNumbers() throws {
        let search = WorkspaceSearch("OPS 12 café incident 23")
        let exact = try #require(search.score(title: "Café Incident 23 Review", context: "Ops 12"))
        let prefix = try #require(search.score(title: "Cafe Incident 230 Review", context: "Ops 120"))
        #expect(exact > prefix)
        #expect(search.score(title: "Café Incident 23 Review", context: "Ops 1") == nil)
        #expect(search.score(title: "Café Incident 2 Review", context: "Ops 12") == nil)
    }

    @Test func attentionDoesNotCrossWorkspacesAndApprovalsComeFirst() {
        let first = WorkspaceChatID(workspace: "first", chat: "shared-id")
        let second = WorkspaceChatID(workspace: "second", chat: "shared-id")
        let sample = Date(timeIntervalSince1970: 100)
        let reply = WorkspaceAttention(chat: first, title: "First", reason: .reply, date: sample)
        let approval = WorkspaceAttention(chat: second, title: "Second", reason: .approval, date: sample)
        let saved = WorkspaceAttention(chat: first, title: "First", reason: .followUp, date: sample.addingTimeInterval(100))
        #expect(Set([reply.id, approval.id, saved.id]).count == 3)
        #expect(WorkspaceAttention.prioritized([reply, saved, approval]).map(\.reason) == [.approval, .reply, .followUp])
        #expect(WorkspaceAttention.onePerChat([saved, reply, approval]) == [approval, reply])
    }

    @Test func desktopPresenceOnlyHoldsAlertsWhileItIsFreshAndActive() {
        let now = Date(timeIntervalSince1970: 1000)
        let policy = AttentionPolicy(delivery: .whenAway)
        #expect(!policy.allows(.approval, appIsActive: false, desktop: DesktopPresence(active: true, observedAt: 980), now: now))
        #expect(policy.allows(.approval, appIsActive: false, desktop: DesktopPresence(active: true, observedAt: 900), now: now))
        #expect(policy.allows(.approval, appIsActive: false, desktop: DesktopPresence(active: false, observedAt: 999), now: now))
        #expect(policy.allows(.reply, appIsActive: false, desktop: nil, now: now))
        #expect(!policy.allows(.reply, appIsActive: true, desktop: nil, now: now))
        #expect(!policy.allows(.followUp, appIsActive: false, desktop: nil, now: now))
        #expect(!AttentionPolicy(delivery: .off).allows(.approval, appIsActive: false, desktop: nil, now: now))
        #expect(!AttentionPolicy(delivery: .always, replies: false).allows(.reply, appIsActive: false, desktop: nil, now: now))
    }

    @Test func appServerStatusDistinguishesInputApprovalAndUnloaded() throws {
        let approval = try #require(CodexChatSummary(["id": "chat", "status": [
            "type": "active", "activeFlags": .array(["waitingOnApproval"])
        ]]))
        #expect(approval.status == .approval)
        let input = try #require(CodexChatSummary(["id": "chat", "status": [
            "type": "active", "activeFlags": .array(["waitingOnUserInput"])
        ]]))
        #expect(input.status == .input)
        let unloaded = try #require(CodexChatSummary(["id": "chat", "status": ["type": "notLoaded"]]))
        #expect(unloaded.status == .unknown)
    }

    @Test func liveTurnUsesStableItemIdentityAndNeverReadsRawReasoning() throws {
        let initial = try #require(CodexWorkDecoder.decode("item/started", ["item": [
            "id": "cmd1", "type": "commandExecution", "command": "swift test", "status": "inProgress"
        ]]))
        let output = try #require(CodexWorkDecoder.decode("item/commandExecution/outputDelta", [
            "itemId": "cmd1", "delta": "Compiling module"
        ]))
        let final = try #require(CodexWorkDecoder.decode("item/completed", ["item": [
            "id": "cmd1", "type": "commandExecution", "command": "swift test", "status": "completed",
            "aggregatedOutput": "Build finished"
        ]]))
        var progress = CodexTurnProgress()
        progress.apply(initial)
        progress.apply(output)
        #expect(progress.current?.detail == "Compiling module")
        progress.apply(final)
        #expect(progress.current == nil)
        #expect(progress.items.map(\.detail) == ["Build finished"])
        #expect(CodexWorkDecoder.decode("item/reasoning/textDelta", ["itemId": "summary", "delta": "not displayable"]) == nil)
        let summary = try #require(CodexWorkDecoder.decode("item/completed", ["item": [
            "id": "summary", "type": "reasoning", "summary": .array(["Reviewed inputs"]),
            "content": .array(["not displayable"])
        ]]))
        progress.apply(summary)
        #expect(progress.items.last?.detail == "Reviewed inputs")
    }

    @Test func relayRequiresTLSAndKeepsPairingSecretInTheAuthorizationHeader() async throws {
        let token = String(repeating: "t", count: 40)
        #expect(AttentionRelay(origin: "http://host.example", bearer: token) == nil)
        #expect(AttentionRelay(origin: "https://host.example/?token=one", bearer: token) == nil)
        let request: @Sendable (URLRequest) async throws -> Data = { request in
            #expect(request.url?.absoluteString == "https://relay.example:9443/v1/presence")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
            #expect(request.httpMethod == "GET")
            return Data(#"{"active":true,"observedAt":9876}"#.utf8)
        }
        let relay = try #require(AttentionRelay(origin: "https://relay.example:9443", bearer: token, request: request))
        #expect(try await relay.presence() == DesktopPresence(active: true, observedAt: 9876))
    }

    @Test func relayRequestsThePresenceOfOnlyTheAttentionEventsWorkspace() async throws {
        let request: @Sendable (URLRequest) async throws -> Data = { request in
            #expect(request.url?.absoluteString == "https://relay.example/v1/presence?workspace=work-codex")
            return Data("null".utf8)
        }
        let relay = try #require(AttentionRelay(origin: "https://relay.example", bearer: String(repeating: "t", count: 40), request: request))
        #expect(try await relay.presence(workspace: "work-codex") == nil)
    }
}
