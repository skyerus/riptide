import Foundation

struct CodexThreadSettings {
    var model: String
    let provider: String?
    var effort: String?
    var serviceTier: String?

    init?(_ value: JSON) {
        guard let model = value["model"]?.string, !model.isEmpty else { return nil }
        self.model = model
        provider = value["modelProvider"]?.string
        effort = value["effort"]?.string ?? value["reasoningEffort"]?.string
        serviceTier = value["serviceTier"]?.string
    }

    func configOptions(catalog: [CodexCatalogModel]) -> [SessionConfigOption] {
        let current = catalog.first { $0.id == model }
        let models = catalog.filter { !$0.hidden || $0.id == model }.map(\.choice)
        var options = [SessionConfigOption(id: "model", name: "Model", category: .model,
                                           currentValue: model, choices: models)]
        if let current, !current.efforts.isEmpty {
            options.append(.init(id: "effort", name: "Reasoning effort", category: .thoughtLevel,
                                 currentValue: effort ?? current.defaultEffort ?? "", choices: current.efforts))
        }
        if let current, let fast = current.fastTier {
            let selectedTier = serviceTier ?? current.defaultTier ?? "default"
            let selected = selectedTier == fast || ["fast", "priority"].contains(selectedTier) ? "fast" : selectedTier
            options.append(.init(id: "service_tier", name: "Speed", category: .serviceTier, currentValue: selected,
                                 choices: [.init(id: "default", name: "Standard", description: nil, group: nil),
                                           .init(id: "fast", name: "Fast", description: nil, group: nil)]))
        }
        return options
    }
}

struct CodexCatalogModel {
    let id: String
    let choice: SessionConfigOption.Choice
    let hidden: Bool
    let efforts: [SessionConfigOption.Choice]
    let defaultEffort: String?
    let fastTier: String?
    let defaultTier: String?

    init?(_ value: JSON) {
        guard let model = value["model"]?.string ?? value["id"]?.string, !model.isEmpty else { return nil }
        id = model
        let shortName = SessionConfigOption.displayLabels(model, value: model, category: .model).name
        let name = shortName == model ? value["displayName"]?.string ?? model : shortName
        choice = .init(id: model, name: name, description: value["description"]?.string, group: nil)
        hidden = value["hidden"] == .boolean(true)
        efforts = (value["supportedReasoningEfforts"]?.array ?? []).compactMap { entry in
            guard let id = entry["reasoningEffort"]?.string else { return nil }
            let name = SessionConfigOption.displayLabels(id, value: id, category: .thoughtLevel).name
            return .init(id: id, name: name, description: entry["description"]?.string, group: nil)
        }
        defaultEffort = value["defaultReasoningEffort"]?.string
        let nativeTier = value["serviceTiers"]?.array?.first { $0["name"]?.string?.lowercased() == "fast" }?["id"]?.string
        let legacyFast = value["additionalSpeedTiers"]?.array?.contains("fast") == true
        fastTier = nativeTier ?? (legacyFast ? "priority" : nil)
        defaultTier = value["defaultServiceTier"]?.string
    }
}
