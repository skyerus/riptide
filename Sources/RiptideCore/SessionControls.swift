import Foundation

public struct SessionConfigOption: Identifiable, Equatable, Sendable {
    public enum Category: String, Sendable {
        case model
        case thoughtLevel = "thought_level"
        case serviceTier = "service_tier"
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
        currentChoice?.name ?? Self.fallbackName(currentValue, category: category)
    }

    public var currentChoice: Choice? { choices.first { $0.id == currentValue } }

    public var fastMode: Bool? {
        guard category == .serviceTier, standardSpeedID != nil, choices.contains(where: { $0.id == "fast" }) else { return nil }
        return currentValue == "fast"
    }

    public var standardSpeedID: String? {
        choices.first { $0.id == "normal" || $0.id == "default" }?.id
    }

    static func parse(_ options: [JSON]) -> [Self] {
        options.compactMap { option in
            guard option["type"] == "select", let id = option["id"]?.string,
                  let name = option["name"]?.string, let kind = option["category"]?.string,
                  let category = Category(rawValue: id == "service_tier" && kind == "other" ? id : kind),
                  let current = option["currentValue"]?.string,
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
            return Self(id: id, name: name, category: category, currentValue: current, choices: choices)
        }
    }

    static func reportedModelName(in response: JSON) -> String? {
        guard let models = response["models"], let current = models["currentModelId"]?.string else { return nil }
        let choice = models["availableModels"]?.array?.first { $0["modelId"]?.string == current }
        if let name = choice?["name"]?.string, !name.isEmpty {
            return displayLabels(name, value: current, category: .model).name
        }
        return fallbackName(current, category: .model)
    }

    private static func fallbackName(_ value: String, category: Category) -> String? {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if category == .model, let rawModel = name.split(separator: ":").last {
            let model = String(rawModel)
            let compactName = compactModelName(model)
            if compactName != model { return compactName }
        }
        return displayLabels(name, value: name, category: category).name
    }

    static func displayLabels(_ name: String, value: String, category: Category) -> (name: String, provider: String?) {
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
        case .serviceTier:
            return (name, nil)
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
    var reportedModelName: String? = nil
}
