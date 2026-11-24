import AppKit
import CoreGraphics
import Foundation

private final class PresenceSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct PresenceReport: Encodable {
    let workspace: String
    let active: Bool
}

@main struct DesktopPresenceReporter {
    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 5,
              (1...160).contains(arguments[3].utf8.count),
              arguments[3].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }),
              var parts = URLComponents(string: arguments[1]),
              let host = parts.host, !host.isEmpty,
              parts.scheme == "https" || (parts.scheme == "http" && host == "127.0.0.1"),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path == "" || parts.path == "/" else {
            print("Usage: desktop-presence <relay-origin> <publisher-token-file> <workspace-id> <app-bundle-id> [...]")
            return
        }
        let file = URL(filePath: arguments[2])
        let properties = try FileManager.default.attributesOfItem(atPath: file.path())
        guard let mode = properties[.posixPermissions] as? Int, mode & 0o077 == 0,
              properties[.type] as? FileAttributeType == .typeRegular else {
            print("Use a private publisher token file (mode 0600).")
            return
        }
        let token = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (32...512).contains(token.utf8.count),
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.~+/=".contains($0)) }) else {
            print("Invalid publisher token.")
            return
        }
        parts.path = "/v1/presence"
        guard let url = parts.url else { return }
        let workspace = arguments[3]
        let apps = Set(arguments.dropFirst(4))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: PresenceSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let events: [CGEventType] = [
            .keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDown, .otherMouseDragged, .scrollWheel
        ]
        while !Task.isCancelled {
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let idle = events.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
                .filter { $0.isFinite && $0 >= 0 }.min() ?? .infinity
            let active = frontmost.map { apps.contains($0) } == true && idle <= 35
            var request = URLRequest(url: url, timeoutInterval: 5)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(PresenceReport(workspace: workspace, active: active))
            if let (_, response) = try? await session.data(for: request),
               let status = (response as? HTTPURLResponse)?.statusCode, status == 401 {
                print("The relay did not accept the publisher credential.")
                return
            }
            try await Task.sleep(for: .seconds(8))
        }
    }
}
