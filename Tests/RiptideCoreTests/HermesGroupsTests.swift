import Foundation
import Testing
@testable import RiptideCore

struct HermesGroupsTests {
    @Test func profilesUseTheSeatableRosterAndCreationKeepsTheirIdentity() async throws {
        let client = HermesGroupsClient { frame in
            let request = try JSONDecoder().decode(JSON.self, from: frame)
            let result: JSON
            switch request["method"]?.string {
            case "groups.capabilities":
                result = ["driver": .boolean(true), "seatable_profiles": .array(["sable", "skye"])]
            case "profiles.list":
                #expect(request["params"]?["include_sessions"] == .boolean(false))
                result = ["profiles": .array([
                    ["name": "sable", "display_name": "Sable Accountant"],
                    ["name": "skye", "display_name": "Skye Accountant"],
                    ["name": "outside", "display_name": "Other bot"],
                ])]
            case "groups.create":
                let params = try #require(request["params"])
                let members = try #require(params["members"]?.array)
                #expect(members.map { $0["profile"] } == ["sable", "skye"])
                #expect(members.map { $0["handle"] } == ["sable", "skye"])
                #expect(params["room_id"] == "review-id")
                result = ["room": ["room_id": "review-id", "name": "Review", "members": .array(members)]]
            default:
                throw HermesGroupError.invalidReply
            }
            return try JSONEncoder().encode(JSON.reply(try #require(request["id"]), result: result))
        }
        let capabilities = try await client.capabilities()
        let bots = try await client.bots(capabilities: capabilities)
        let room = try await client.create(id: "review-id", name: "Review", bots: bots)
        #expect(room.members.map(\.label) == ["Sable Accountant", "Skye Accountant"])
    }

    @Test func retryKeepsTheSameEventAndThreadAndRequiresItsReceipt() async throws {
        let intent = HermesGroupSend(text: "@skye Compare both checklists.", thread: "original-topic")
        let reply = SendReply()
        let client = HermesGroupsClient { frame in
            let request = try JSONDecoder().decode(JSON.self, from: frame)
            let params = try #require(request["params"])
            #expect(request["method"] == "groups.send")
            #expect(params["event_id"] == .string(intent.id))
            #expect(params["payload"]?["thread_id"] == "original-topic")
            #expect(params["payload"]?["text"] == "@skye Compare both checklists.")
            let receipt = await reply.receipt(for: intent.id)
            return try JSONEncoder().encode(JSON.reply(try #require(request["id"]), result: receipt))
        }
        await #expect(throws: HermesGroupError.self) { try await client.send(intent, room: "review-id") }
        try await client.send(intent, room: "review-id")
    }
}

private actor SendReply {
    private var attempted = false

    func receipt(for id: String) -> JSON {
        defer { attempted = true }
        return ["client_event_id": .string(attempted ? id : "different-message"), "accepted": .boolean(true)]
    }
}
