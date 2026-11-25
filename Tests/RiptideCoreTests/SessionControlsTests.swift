import Testing
@testable import RiptideCore

struct SessionControlsTests {
    @Test func modelSelectionShortensLabelsWithoutChangingProviderOrWireValues() throws {
        let options = SessionConfigOption.parse([
            ["id": "model", "type": "select", "name": "Model", "category": "model",
             "currentValue": "openai-codex:gpt-6.2-sol", "options": .array([
                ["value": "openai-codex:gpt-6.2-sol", "name": "ChatGPT or Codex Subscription · gpt-6.2-sol"],
                ["value": "openai-codex:gpt-6.1-sol-900k", "name": "ChatGPT or Codex Subscription · gpt-6.1-sol-900k"],
                ["value": "experimental", "name": "Experimental · Preview"],
                ["value": "openai:gpt-6.2-sol", "name": "OpenAI API · gpt-6.2-sol"]
             ])]
        ])
        let model = try #require(options.first)
        #expect(model.currentName == "6.2 Sol")
        #expect(model.currentChoice?.group == "ChatGPT or Codex Subscription")
        #expect(model.choices.map(\.name) == ["6.2 Sol", "6.1 Sol · 900K", "Experimental · Preview", "6.2 Sol"])
        #expect(model.choices.last?.group == "OpenAI API")
        #expect(model.choices.map(\.id) == [
            "openai-codex:gpt-6.2-sol", "openai-codex:gpt-6.1-sol-900k", "experimental", "openai:gpt-6.2-sol"
        ])
    }

    @Test func structuredGroupsAndEffortUseBackendOrdering() throws {
        let options = SessionConfigOption.parse([
            ["id": "model", "type": "select", "name": "Model", "category": "model",
             "currentValue": "atlas", "options": .array([
                ["group": "recommended", "name": "Recommended", "options": .array([
                    ["value": "atlas", "name": "Atlas"], ["value": "atlas", "name": "Duplicate"]
                ])]
             ])],
            ["id": "reasoning_effort", "type": "select", "name": "Reasoning effort", "category": "thought_level",
             "currentValue": "xhigh", "options": .array([
                ["value": "medium", "name": "medium"], ["value": "xhigh", "name": "xhigh"],
                ["value": "agent-specific", "name": "Agent-specific"]
             ])]
        ])
        let model = try #require(options.first)
        #expect(model.choices.map(\.id) == ["atlas"])
        #expect(model.currentChoice?.group == "Recommended")
        let effort = try #require(options.last)
        #expect(effort.currentName == "Extra High")
        #expect(effort.choices.map(\.id) == ["medium", "xhigh", "agent-specific"])
        #expect(effort.choices.map(\.name) == ["Medium", "Extra High", "Agent-specific"])
    }
}
