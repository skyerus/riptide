import Foundation

public enum AttentionDelivery: String, CaseIterable, Identifiable, Codable, Sendable {
    case off, whenAway, always

    public var id: Self { self }

    public var title: String {
        switch self {
        case .off: "Off"
        case .whenAway: "When I’m away"
        case .always: "Always"
        }
    }
}

public struct DesktopPresence: Codable, Equatable, Sendable {
    public let active: Bool
    public let observedAt: TimeInterval

    public init(active: Bool, observedAt: TimeInterval) {
        self.active = active
        self.observedAt = observedAt
    }

    public func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince1970 - observedAt
        return age.isFinite && (-5...45).contains(age)
    }
}

public struct AttentionPolicy: Codable, Equatable, Sendable {
    public var delivery: AttentionDelivery
    public var approvals: Bool
    public var replies: Bool

    public init(delivery: AttentionDelivery = .off, approvals: Bool = true, replies: Bool = true) {
        self.delivery = delivery
        self.approvals = approvals
        self.replies = replies
    }

    public func allows(_ reason: AttentionReason, appIsActive: Bool, desktop: DesktopPresence?, now: Date = .now) -> Bool {
        guard delivery != .off, !appIsActive else { return false }
        switch reason {
        case .approval, .input: guard approvals else { return false }
        case .reply: guard replies else { return false }
        case .followUp: return false
        }
        if delivery == .whenAway, let desktop, desktop.isFresh(at: now) && desktop.active { return false }
        return true
    }
}
