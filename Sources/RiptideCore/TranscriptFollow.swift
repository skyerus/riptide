public struct TranscriptFollow: Equatable, Sendable {
    public private(set) var following = true
    public private(set) var interacting = false

    public init(following: Bool = true) {
        self.following = following
    }

    public var canScrollAutomatically: Bool { following && !interacting }

    public mutating func phaseChanged(userGesture: Bool, nearBottom: Bool) {
        if interacting && !userGesture { following = nearBottom }
        interacting = userGesture
    }

    public mutating func geometryChanged(nearBottom: Bool) {
        if interacting { following = nearBottom }
    }

    public mutating func jumpToLatest() {
        following = true
        interacting = false
    }
}
