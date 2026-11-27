import Foundation

public struct VoiceTranscriptLine: Codable, Equatable, Sendable {
    public let role: ChatRole
    public let text: String

    public init(role: ChatRole, text: String) {
        self.role = role
        self.text = text
    }
}

/// Keeps interim speech at its original position and replaces it when a final transcript arrives.
public struct VoiceTranscript: Sendable {
    private struct Segment: Sendable {
        var role: ChatRole
        var text: String
        var itemID: String?
        var final: Bool
    }

    private var segments: [Segment] = []

    public init() {}

    public var lines: [VoiceTranscriptLine] {
        segments.compactMap {
            let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : VoiceTranscriptLine(role: $0.role, text: text)
        }
    }

    public mutating func append(role: ChatRole, text: String, itemID: String? = nil, final: Bool) {
        guard !text.isEmpty else { return }
        let identified = itemID.flatMap { id in segments.lastIndex { $0.role == role && $0.itemID == id } }
        let pending = segments.lastIndex { $0.role == role && !$0.final && ($0.itemID == nil || itemID == nil) }
        let uninterrupted = pending == segments.indices.last ? pending : nil
        if let index = identified ?? (final ? pending : uninterrupted) {
            guard !segments[index].final else { return }
            if final { segments[index].text = String(text.prefix(16_000)) }
            else { segments[index].text += text.prefix(max(0, 16_000 - segments[index].text.count)) }
            segments[index].itemID = itemID ?? segments[index].itemID
            segments[index].final = final
        } else if segments.count < 1_000 {
            segments.append(Segment(role: role, text: String(text.prefix(16_000)), itemID: itemID, final: final))
        }
    }
}

extension VoiceTranscript {
    mutating func acceptHermesEvent(_ event: JSON) {
        guard let role = event["role"]?.string.flatMap(ChatRole.init(rawValue:)),
              let text = event["text"]?.string else { return }
        append(role: role, text: text, itemID: event["item_id"]?.string,
               final: event["final"] == .boolean(true))
    }

    public mutating func acceptHermesMedia(_ data: Data, listening: Bool) {
        guard let event = try? JSONDecoder().decode(JSON.self, from: data) else { return }
        switch event["type"]?.string {
        case "session.input_transcript.delta" where listening:
            if let text = event["delta"]?.string {
                append(role: .user, text: text, itemID: event["item_id"]?.string, final: false)
            }
        case "session.output_transcript.delta":
            if let text = event["delta"]?.string {
                append(role: .assistant, text: text, itemID: event["item_id"]?.string, final: false)
            }
        case "input_transcript.added" where listening, "output_transcript.added":
            if let text = event["item"]?["text"]?.string {
                append(role: event["type"] == "input_transcript.added" ? .user : .assistant,
                       text: text, itemID: event["item"]?["id"]?.string, final: true)
            }
        case "turn.done":
            if let turn = event["turn"], let role = turn["role"]?.string.flatMap(ChatRole.init(rawValue:)),
               role == .assistant || listening, let text = turn["transcript"]?.string {
                append(role: role, text: text, itemID: turn["id"]?.string, final: true)
            }
        default:
            break
        }
    }
}
