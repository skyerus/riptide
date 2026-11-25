import Foundation
import RiptideCore
import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private static let operations: Set<String> = ["state", "grant", "next", "result", "release"]
    private static let relay = SafariSSHRelay()

    func beginRequest(with context: NSExtensionContext) {
        let reply = Reply(context: context)
        guard let input = context.inputItems.first as? NSExtensionItem,
              let message = input.userInfo?[SFExtensionMessageKey] as? [String: Any],
              let operation = message["operation"] as? String else {
            reply.send(error: "Invalid Safari handoff request.")
            return
        }

        let agents: [SafariSSHAgent]
        do {
            guard let store = SafariSSHKeychain() else { throw SafariSSHError.keychain }
            agents = try store.load()
        } catch {
            reply.send(error: error.localizedDescription)
            return
        }

        if operation == "agents" {
            reply.send(["status": 200, "body": [
                "agents": agents.map { ["id": $0.profile.id.uuidString, "name": $0.profile.name] }
            ]])
            return
        }
        guard Self.operations.contains(operation),
              let value = message["agentID"] as? String, let id = UUID(uuidString: value),
              let body = message["body"] as? [String: Any],
              let frame = try? JSONSerialization.data(withJSONObject: ["operation": operation, "body": body]),
              frame.count < 96 * 1024 else {
            reply.send(error: "Invalid Safari handoff request.")
            return
        }
        guard let agent = agents.first(where: { $0.profile.id == id }) else {
            reply.send(error: SafariSSHError.pairing.localizedDescription, status: 404)
            return
        }
        Task {
            do {
                let data = try await Self.relay.request(frame, from: agent)
                guard data.count <= 96 * 1024,
                      let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let status = response["status"] as? Int,
                      let body = response["body"] as? [String: Any] else { throw SafariSSHError.unavailable }
                reply.send(["status": status, "body": body])
            } catch {
                reply.send(error: error.localizedDescription)
            }
        }
    }

    // The request context is completed once, either during validation or from the relay task.
    private struct Reply: @unchecked Sendable {
        let context: NSExtensionContext

        func send(error: String, status: Int = 503) {
            send(["status": status, "body": ["error": error]])
        }

        func send(_ message: [String: Any]) {
            let output = NSExtensionItem()
            output.userInfo = [SFExtensionMessageKey: message]
            context.completeRequest(returningItems: [output])
        }
    }
}
