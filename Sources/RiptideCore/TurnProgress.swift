import Foundation

public struct TurnPlanStep: Equatable, Sendable {
    public enum State: String, Sendable { case pending, inProgress, completed }

    public let text: String
    public let state: State

    init?(_ item: JSON) {
        guard let text = (item["step"] ?? item["content"])?.string, !text.isEmpty else { return nil }
        self.text = String(text.prefix(280))
        switch item["status"]?.string {
        case "inProgress", "in_progress": state = .inProgress
        case "completed": state = .completed
        default: state = .pending
        }
    }
}

public struct CodexWorkItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case command, changes, tool, search, planning, summary }
    public enum State: String, Sendable { case running, finished, failed }

    public let id: String
    public let kind: Kind
    public let title: String
    public let state: State
    public var detail: String

    init?(_ item: JSON, completed: Bool) {
        guard let id = item["id"]?.string, let type = item["type"]?.string else { return nil }
        self.id = id
        let name: String
        var output = ""
        switch type {
        case "commandExecution":
            kind = .command
            name = item["command"]?.string ?? "Run a command"
            output = item["aggregatedOutput"]?.string ?? ""
        case "fileChange":
            kind = .changes
            let paths = item["changes"]?.array?.prefix(8).compactMap { $0["path"]?.string } ?? []
            name = paths.isEmpty ? "Edit files" : "Update \(paths.count) \(paths.count == 1 ? "file" : "files")"
            output = paths.joined(separator: "\n")
        case "mcpToolCall", "dynamicToolCall", "collabToolCall":
            kind = .tool
            let tool = item["tool"]?.string ?? "Tool call"
            name = [item["server"]?.string, tool].compactMap { $0 }.joined(separator: " · ")
        case "webSearch":
            kind = .search
            name = item["query"]?.string ?? "Search the web"
        case "plan":
            kind = .planning
            name = "Proposed plan"
            output = item["text"]?.string ?? ""
        case "reasoning":
            kind = .summary
            name = "Reasoning summary"
            output = item["summary"]?.array?.compactMap(\.string).joined(separator: "\n\n") ?? ""
        default:
            return nil
        }
        title = String(name.prefix(220))
        detail = String(output.suffix(2_800))
        let status = item["status"]?.string
        if ["failed", "declined", "interrupted", "cancelled"].contains(status ?? "") ||
            (item["exitCode"]?.integer ?? 0) != 0 || item["success"] == .boolean(false) {
            state = .failed
        } else {
            state = completed || status == "completed" ? .finished : .running
        }
    }
}

public enum CodexWorkUpdate: Equatable, Sendable {
    case item(CodexWorkItem)
    case detail(id: String, kind: CodexWorkItem.Kind, text: String)
    case plan([TurnPlanStep])
}

public struct CodexTurnProgress: Equatable, Sendable {
    public private(set) var plan: [TurnPlanStep] = []
    public private(set) var items: [CodexWorkItem] = []

    public init() {}

    public var current: CodexWorkItem? { items.last { $0.state == .running } }
    public var hasContent: Bool { !plan.isEmpty || !items.isEmpty }

    public mutating func apply(_ update: CodexWorkUpdate) {
        switch update {
        case .plan(let steps):
            plan = steps
        case .item(var item):
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                if item.detail.isEmpty { item.detail = items[index].detail }
                items[index] = item
            } else {
                if items.count >= 32 {
                    items.remove(at: items.firstIndex { $0.state != .running } ?? items.startIndex)
                }
                items.append(item)
            }
        case .detail(let id, let kind, let text):
            if let index = items.firstIndex(where: { $0.id == id && $0.kind == kind }) {
                items[index].detail = String((items[index].detail + text).suffix(2_800))
            }
        }
    }
}

enum CodexWorkDecoder {
    static func decode(_ method: String, _ params: JSON) -> CodexWorkUpdate? {
        switch method {
        case "turn/plan/updated":
            guard let steps = params["plan"]?.array else { return nil }
            return .plan(steps.prefix(24).compactMap { TurnPlanStep($0) })
        case "item/started", "item/completed":
            guard let item = params["item"], let work = CodexWorkItem(item, completed: method == "item/completed") else { return nil }
            return .item(work)
        case "item/commandExecution/outputDelta", "item/reasoning/summaryTextDelta", "item/plan/delta":
            guard let id = params["itemId"]?.string, let text = params["delta"]?.string else { return nil }
            let kind: CodexWorkItem.Kind = method == "item/commandExecution/outputDelta" ? .command
                : method == "item/plan/delta" ? .planning : .summary
            return .detail(id: id, kind: kind, text: String(text.suffix(2_800)))
        default:
            return nil
        }
    }
}
