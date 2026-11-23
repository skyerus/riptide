public struct SessionConfigOption: Identifiable, Equatable, Sendable {
    public enum Category: String, Sendable {
        case model
        case thoughtLevel = "thought_level"
    }

    public struct Choice: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let description: String?
    }

    public let id: String
    public let name: String
    public let category: Category
    public let currentValue: String
    public let choices: [Choice]

    public var currentName: String? {
        choices.first(where: { $0.id == currentValue })?.name
    }

    static func parse(_ options: [JSON]) -> [Self] {
        options.compactMap { option in
            guard option["type"] == "select", let id = option["id"]?.string,
                  let name = option["name"]?.string, let kind = option["category"]?.string,
                  let category = Category(rawValue: kind), let current = option["currentValue"]?.string,
                  let entries = option["options"]?.array else { return nil }
            var values = Set<String>()
            let choices = entries.flatMap { $0["options"]?.array ?? [$0] }.compactMap { entry -> Choice? in
                guard let value = entry["value"]?.string, let name = entry["name"]?.string,
                      values.insert(value).inserted else { return nil }
                return Choice(id: value, name: name, description: entry["description"]?.string)
            }
            guard !choices.isEmpty else { return nil }
            return Self(id: id, name: name, category: category, currentValue: current, choices: choices)
        }
    }
}

public struct ContextUsage: Equatable, Sendable {
    public let used: Int
    public let capacity: Int

    public var fraction: Double {
        min(Double(used) / Double(capacity), 1)
    }

    init?(used: Int, capacity: Int) {
        guard used >= 0, capacity > 0 else { return nil }
        self.used = used
        self.capacity = capacity
    }
}

public struct OpenedSession: Sendable {
    public let id: String
    public let configOptions: [SessionConfigOption]?
    public let events: [ACPEvent]
    public var nativeSessionKey: String? = nil
}
