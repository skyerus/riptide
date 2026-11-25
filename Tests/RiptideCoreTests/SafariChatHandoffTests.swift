import Foundation
import Testing
@testable import RiptideCore

struct SafariChatHandoffTests {
    @Test func onlyExplicitFirstPersonConfirmationsApproveTheTab() {
        for message in ["I've signed in.", "I’ve signed in!", "  I'M LOGGED IN  ", "I have signed in"] {
            #expect(SafariChatHandoff.isConfirmation(message), Comment(rawValue: message))
        }
        for message in ["Have I signed in?", "I’ve signed in?", "I haven’t signed in", "When I’ve signed in",
                        "Hermes says I've signed in", "Please sign in", "I’ve signed in on another tab"] {
            #expect(!SafariChatHandoff.isConfirmation(message), Comment(rawValue: message))
        }
    }

    @Test func approvalUsesSeparateOriginBoundTokensAndPreservesTheSiteFragment() throws {
        let request = try JSONDecoder().decode(SafariChatHandoff.Request.self, from: Data(#"""
        {"id":"request-id","url":"https://example.com/login?to=apps#section%202","origin":"https://example.com","active":false}
        """#.utf8))
        let now = Date(timeIntervalSince1970: 1_000)
        var handoff = SafariChatHandoff(request: request, agentID: UUID(), chatID: "chat", now: now)
        #expect(handoff.launchURL?.absoluteString == "https://example.com/login?to=apps#riptide-handoff=\(handoff.openToken)&section%202")
        #expect(handoff.tokenPurpose(handoff.openToken, origin: "https://example.com", now: now) == "open")
        #expect(handoff.tokenPurpose(handoff.openToken, origin: "https://other.example", now: now) == nil)
        #expect(handoff.resumeURL == nil)

        handoff.approve(now: now)
        let resume = try #require(handoff.resumeToken)
        #expect(resume != handoff.openToken)
        #expect(handoff.tokenPurpose(handoff.openToken, origin: "https://example.com", now: now) == nil)
        #expect(handoff.tokenPurpose(resume, origin: "https://example.com", now: now) == "resume")
        #expect(handoff.tokenPurpose(resume, origin: "https://example.com", now: now.addingTimeInterval(30)) == nil)
    }
}
