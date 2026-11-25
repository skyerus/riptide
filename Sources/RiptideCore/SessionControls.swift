import Foundation

public struct SessionConfigOption: Identifiable, Equatable, Sendable {
    public enum Category: String, Sendable {
        case model
        case thoughtLevel = "thought_level"
    }

    public struct Choice: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let description: String?
        public let group: String?
    }

    public let id: String
    public let name: String
    public let category: Category
    public let currentValue: String
    public let choices: [Choice]

    public var currentName: String? {
        currentChoice?.name
    }

    public var currentChoice: Choice? { choices.first { $0.id == currentValue } }

    static func parse(_ options: [JSON]) -> [Self] {
        options.compactMap { option in
            guard option["type"] == "select", let id = option["id"]?.string,
                  let name = option["name"]?.string, let kind = option["category"]?.string,
                  let category = Category(rawValue: kind), let current = option["currentValue"]?.string,
                  let entries = option["options"]?.array else { return nil }
            var values = Set<String>()
            let choices = entries.flatMap { group in
                (group["options"]?.array ?? [group]).compactMap { entry -> Choice? in
                    guard let value = entry["value"]?.string, let name = entry["name"]?.string,
                          values.insert(value).inserted else { return nil }
                    let labels = displayLabels(name, value: value, category: category)
                    let groupName = group["options"]?.array == nil ? nil : group["name"]?.string
                    return Choice(id: value, name: labels.name, description: entry["description"]?.string,
                                  group: groupName ?? labels.provider)
                }
            }
            guard !choices.isEmpty else { return nil }
            return Self(id: id, name: name, category: category, currentValue: current, choices: choices)
        }
    }

    private static func displayLabels(_ name: String, value: String, category: Category) -> (name: String, provider: String?) {
        switch category {
        case .model:
            if let split = name.range(of: " · ") {
                let model = String(name[split.upperBound...])
                if !model.isEmpty, value == model || value.hasSuffix(":\(model)") {
                    return (compactModelName(model), String(name[..<split.lowerBound]))
                }
            }
            return (compactModelName(name), nil)
        case .thoughtLevel:
            switch name.lowercased() {
            case "xhigh", "extra-high", "extra_high": return ("Extra High", nil)
            case "none", "minimal", "low", "medium", "high", "max", "ultra": return (name.capitalized, nil)
            default: return (name, nil)
            }
        }
    }

    private static func compactModelName(_ name: String) -> String {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard (3...4).contains(parts.count), parts[0] == "gpt" else { return name }
        let version = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard version.first == "6", version.count <= 2,
              version.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              !parts[2].isEmpty, parts[2].allSatisfy(\.isLetter) else { return name }
        let shortName = "\(parts[1]) \(parts[2].capitalized)"
        if parts.count == 3 { return shortName }
        let size = parts[3].dropLast()
        guard parts[3].last == "k", !size.isEmpty, size.allSatisfy(\.isNumber) else { return name }
        return "\(shortName) · \(parts[3].uppercased())"
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
