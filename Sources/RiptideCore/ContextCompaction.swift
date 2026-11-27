import Foundation

public struct ContextCompaction: Equatable, Identifiable, Sendable {
    public enum State: Equatable, Sendable {
        case running(since: Date)
        case completed(elapsed: TimeInterval?)
    }

    public let id: String
    public let state: State

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    init?(_ item: JSON, running: Bool, replaying: Bool = false, timestamp: JSON? = nil) {
        guard item["type"] == "contextCompaction",
              let id = item["id"]?.string, !id.isEmpty else { return nil }
        let start = Self.date(item["startedAtMs"]) ?? (running ? Self.date(timestamp) : nil)
        let end = Self.date(item["completedAtMs"]) ?? (running ? nil : Self.date(timestamp))
        self.id = id
        if running {
            state = .running(since: start ?? .now)
        } else if !replaying, let start, let end, end >= start {
            state = .completed(elapsed: end.timeIntervalSince(start))
        } else {
            state = .completed(elapsed: nil)
        }
    }

    init?(historicalItem item: JSON, turnInProgress: Bool) {
        let startedOnly = Self.date(item["startedAtMs"]) != nil && Self.date(item["completedAtMs"]) == nil
        guard !startedOnly || turnInProgress else { return nil }
        self.init(item, running: startedOnly, replaying: true)
    }

    /// Older Hermes ACP history serialized this protocol item as one opaque record.
    init?(legacyRecord text: String) {
        let prefix = "[codex contextCompaction] "
        guard text.hasPrefix(prefix), text.utf8.count <= 1_600,
              let item = try? JSONDecoder().decode(JSON.self, from: Data(text.dropFirst(prefix.count).utf8)),
              case .object(let fields) = item,
              Set(fields.keys).isSubset(of: ["type", "id", "startedAtMs", "completedAtMs"]),
              ["startedAtMs", "completedAtMs"].allSatisfy({ key in
                  fields[key] == nil || fields[key] == .null || fields[key]?.integer != nil
              }) else { return nil }
        self.init(item, running: false, replaying: true)
    }

    func merging(_ update: Self) -> Self {
        switch (state, update.state) {
        case (.completed, .running), (.running, .running), (.completed, .completed(elapsed: nil)):
            self
        case (.running(let since), .completed(elapsed: nil)):
            Self(id: id, state: .completed(elapsed: max(0, Date.now.timeIntervalSince(since))))
        default:
            update
        }
    }

    private init(id: String, state: State) {
        self.id = id
        self.state = state
    }

    private static func date(_ value: JSON?) -> Date? {
        guard let milliseconds = value?.integer, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }
}
