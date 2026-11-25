import Foundation
import Testing
@testable import RiptideCore

struct SafariChatHandoffTests {
    @Test func confirmationMustMatchThePendingRequestAndCurrentTurnToken() throws {
        let decoder = JSONDecoder()
        let token = UUID()
        func request(id: String = "request-id", path: String = "login", origin: String = "https://example.com",
                     active: Bool = false, confirmation: UUID? = nil) throws -> SafariChatHandoff.Request {
            var json: [String: Any] = ["id": id, "url": "\(origin)/\(path)", "origin": origin, "active": active]
            json["chat_confirmation"] = confirmation?.uuidString
            return try decoder.decode(SafariChatHandoff.Request.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let now = Date(timeIntervalSince1970: 1_000)
        var handoff = SafariChatHandoff(request: try request(), agentID: UUID(), chatID: "chat", now: now)
        let confirmed = try request(confirmation: token)
        #expect(handoff.acceptsConfirmation(confirmed, token: token, now: now))
        #expect(!handoff.acceptsConfirmation(confirmed, token: UUID(), now: now))
        #expect(try !handoff.acceptsConfirmation(request(), token: token, now: now))
        #expect(try !handoff.acceptsConfirmation(request(id: "other", confirmation: token), token: token, now: now))
        #expect(try !handoff.acceptsConfirmation(request(path: "other", confirmation: token), token: token, now: now))
        #expect(try !handoff.acceptsConfirmation(request(origin: "https://other.example", confirmation: token), token: token, now: now))
        #expect(try !handoff.acceptsConfirmation(request(active: true, confirmation: token), token: token, now: now))
        #expect(!handoff.acceptsConfirmation(confirmed, token: token, now: now.addingTimeInterval(300)))
        handoff.approve(now: now)
        #expect(!handoff.acceptsConfirmation(confirmed, token: token, now: now))
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
