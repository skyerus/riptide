public struct TranscriptFollow: Equatable, Sendable {
    public enum Interaction: Equatable, Sendable { case idle, touching, scrolling }

    public private(set) var following = true
    public private(set) var interaction: Interaction = .idle

    public init(following: Bool = true) {
        self.following = following
    }

    public var canScrollAutomatically: Bool { following && interaction == .idle }

    public mutating func phaseChanged(_ interaction: Interaction, nearBottom: Bool) {
        if self.interaction == .scrolling || interaction == .scrolling { following = nearBottom }
        self.interaction = interaction
    }

    public mutating func geometryChanged(nearBottom: Bool) {
        if interaction == .scrolling { following = nearBottom }
    }

    public mutating func jumpToLatest() {
        following = true
        interaction = .idle
    }
}
