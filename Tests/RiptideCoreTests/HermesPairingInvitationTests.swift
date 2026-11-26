import Foundation
import Testing
@testable import RiptideCore

@Suite struct HermesPairingInvitationTests {
    private func request(callID: String = "clarify-example", name: String) -> PermissionRequest {
        PermissionRequest(id: UUID(), sessionID: "main", title: "Connect a bot", options: [
            .init(id: "choice-0", name: name, kind: "allow_once"),
            .init(id: "skip", name: "Skip", kind: "reject_once")
        ], toolCallID: callID)
    }

    @Test func onlyStructuredClarificationCanInviteAPairing() {
        let valid = request(name: "Pair Hermes profile: skye-digital-ltd-accountant")
        #expect(HermesPairingInvitation(valid)?.profile == "skye-digital-ltd-accountant")
        #expect(HermesPairingInvitation(valid)?.optionID == "choice-0")
        #expect(HermesPairingInvitation(request(callID: "ordinary-tool", name: valid.options[0].name)) == nil)
        #expect(HermesPairingInvitation(request(name: "Pair Hermes profile: ../default")) == nil)
        #expect(HermesPairingInvitation(request(name: "Pair Hermes profile: skye\nother")) == nil)
        #expect(HermesPairingInvitation(request(name: "Browser handoff complete")) == nil)
    }
}
