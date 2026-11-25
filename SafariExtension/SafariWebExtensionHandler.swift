import Foundation
import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private static let operations: Set<String> = ["pair", "state", "grant", "next", "result", "release", "forget"]
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: PrivateRelayDelegate(), delegateQueue: nil)
    }()

    func beginRequest(with context: NSExtensionContext) {
        let reply = Reply(context: context)
        guard let input = context.inputItems.first as? NSExtensionItem,
              let message = input.userInfo?[SFExtensionMessageKey] as? [String: Any],
              let endpoint = message["endpoint"] as? String,
              let operation = message["operation"] as? String, Self.operations.contains(operation),
              let token = message["token"] as? String,
              token.wholeMatch(of: /[A-Za-z0-9_-]{43}/) != nil,
              let body = message["body"] as? [String: Any],
              let encoded = try? JSONSerialization.data(withJSONObject: body), encoded.count <= 96 * 1024,
              let base = URLComponents(string: endpoint), base.scheme == "https",
              base.host?.isEmpty == false, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil, let url = base.url else {
            reply.send(["error": "The private relay address or pairing code is invalid."])
            return
        }
        let route = url.appending(path: "v1").appending(path: "safari").appending(path: operation)
        var request = URLRequest(url: route, timeoutInterval: 7)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = encoded

        Self.session.dataTask(with: request) { data, response, error in
            guard error == nil, let response = response as? HTTPURLResponse,
                  let data, data.count <= 96 * 1024,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                reply.send(["error": "Riptide couldn’t reach the private relay."])
                return
            }
            reply.send(["status": response.statusCode, "body": json])
        }.resume()
    }

    // The request context is completed once, either during validation or from the URLSession callback.
    private struct Reply: @unchecked Sendable {
        let context: NSExtensionContext

        func send(_ message: [String: Any]) {
            let output = NSExtensionItem()
            output.userInfo = [SFExtensionMessageKey: message]
            context.completeRequest(returningItems: [output])
        }
    }
}

private final class PrivateRelayDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
