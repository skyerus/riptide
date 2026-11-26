import Foundation

/// A pairing invitation is a structured Hermes clarification, never chat text.
public struct HermesPairingInvitation: Equatable, Sendable {
    public let profile: String
    public let optionID: String

    public var displayName: String {
        profile.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    public init?(_ request: PermissionRequest) {
        let prefix = "Pair Hermes profile: "
        guard request.toolCallID?.hasPrefix("clarify-") == true, request.options.count == 2,
              request.options.contains(where: { $0.id == "skip" && $0.kind == "reject_once" }),
              let option = request.options.first(where: {
                  $0.id == "choice-0" && $0.kind == "allow_once" && $0.name.hasPrefix(prefix)
              }) else { return nil }
        let slug = String(option.name.dropFirst(prefix.count))
        guard slug.wholeMatch(of: /[a-z0-9][a-z0-9_-]{0,63}/) != nil else { return nil }
        profile = slug
        optionID = option.id
    }
}

enum HermesPairingError: LocalizedError {
    case unavailable
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "The SSH host didn’t return a valid Hermes pairing."
        case .rejected(let message): message
        }
    }
}
