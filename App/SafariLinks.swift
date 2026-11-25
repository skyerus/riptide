import SwiftUI
import UIKit

@MainActor
enum SafariLinks {
    static let openURL = OpenURLAction { url in open(url) }

    static func open(_ url: URL) -> OpenURLAction.Result {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty
        else { return .systemAction }

        // Swap only the scheme so web redirects and Safari handoff fragments survive.
        components.scheme = "x-safari-https"
        guard let safariURL = components.url else { return .systemAction }
        Task {
            let opened = await UIApplication.shared.open(safariURL)
            if !opened {
                _ = await UIApplication.shared.open(url)
            }
        }
        return .handled
    }
}
