#if DEBUG
import Foundation
import RiptideCore

actor HermesGroupsFixture {
    private let file: URL
    private let source: String

    init(namespace: UUID, source: String) {
        self.source = source
        file = .applicationSupportDirectory.appending(path: "HermesGroups-\(namespace.uuidString)-\(source).json")
    }

    func exchange(_ frame: Data) throws -> Data {
        let request = try JSONSerialization.jsonObject(with: frame) as! [String: Any]
        let params = request["params"] as! [String: Any]
        let roomID = params["room_id"] as? String ?? ""
        let stored = try? Data(contentsOf: file)
        let saved = stored.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        var rooms = saved as? [String: [String: Any]] ?? [:]
        let studio = source == "hermes-studio"
        let bots = studio
            ? [["name": "editor", "display_name": "Editor"], ["name": "reviewer", "display_name": "Reviewer"]]
            : [["name": "sable-accountant", "display_name": "Sable Accountant"],
               ["name": "skye-accountant", "display_name": "Skye Accountant"]]
        if stored == nil && studio {
            let members = bots.map { bot in
                ["member_id": bot["name"]!, "profile": bot["name"]!, "handle": bot["name"]!,
                 "display_name": bot["display_name"]!]
            }
            rooms["editorial"] = ["room": ["room_id": "editorial", "name": "Editorial review", "members": members,
                                          "authority_gateway_id": source, "authority_epoch": 1, "latest_seq": 0], "events": []]
        }
        func event(_ id: String, _ seq: Int, _ kind: String, actor: [String: String], text: String, thread: String) -> [String: Any] {
            ["room_id": roomID, "event_id": id, "seq": seq, "kind": kind, "actor": actor,
             "created_at": Date().timeIntervalSince1970, "payload": ["text": text, "thread_id": thread]]
        }
        let driver: [String: Any] = ["running": true, "working": false, "pending_actions": []]
        var result: [String: Any]
        switch request["method"] as? String {
        case "groups.capabilities":
            result = ["driver": true, "seatable_profiles": bots.compactMap { $0["name"] },
                      "methods": ["groups.list", "groups.create", "groups.state", "groups.log", "groups.send", "groups.stop"]]
        case "profiles.list":
            result = ["profiles": bots]
        case "groups.list":
            result = ["rooms": rooms.values.compactMap { $0["room"] }]
        case "groups.create":
            let room: [String: Any] = ["room_id": roomID, "name": params["name"]!, "members": params["members"]!,
                                       "authority_gateway_id": source, "authority_epoch": 1, "latest_seq": 0]
            if rooms[roomID] == nil { rooms[roomID] = ["room": room, "events": []] }
            result = ["room": rooms[roomID]!["room"]!]
        case "groups.state":
            result = ["room": rooms[roomID]!["room"]!, "driver_status": driver]
        case "groups.log":
            let cursor = params["since_seq"] as! Int
            let all = rooms[roomID]!["events"] as! [[String: Any]]
            result = ["events": Array(all.dropFirst(cursor)), "has_more": false, "authority": ["epoch": 1]]
        case "groups.send":
            let id = params["event_id"] as! String
            var record = rooms[roomID]!
            var room = record["room"] as! [String: Any]
            var events = record["events"] as! [[String: Any]]
            var admitted = record["admitted"] as? [String] ?? []
            let payload = params["payload"] as! [String: String]
            let thread = payload["thread_id"]!
            if !admitted.contains(id) {
                let members = room["members"] as! [[String: String]]
                events.append(event(id, events.count + 1, "message.user",
                                    actor: ["kind": "user", "id": "desktop"], text: payload["text"]!, thread: thread))
                let responses = [
                    "I’d start by matching the bank balance to the ledger, then review any unreconciled transactions.",
                    "I’ll cross-check the outstanding invoices against the same checklist and flag anything we need to review together.",
                ]
                for (member, text) in zip(members, responses) {
                    events.append(event(UUID().uuidString, events.count + 1, "message.member",
                                        actor: ["kind": "member", "id": member["member_id"]!, "display_name": member["display_name"]!],
                                        text: text, thread: thread))
                }
                admitted.append(id)
                room["latest_seq"] = events.count
                record = ["room": room, "events": events, "admitted": admitted]
                rooms[roomID] = record
            }
            result = ["accepted": true, "client_event_id": id]
        default:
            result = [:]
        }
        if request["method"] as? String == "groups.create" || request["method"] as? String == "groups.send" {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: rooms).write(to: file, options: .atomic)
        }
        return try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": request["id"]!, "result": result])
    }
}
#endif
