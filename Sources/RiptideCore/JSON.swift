import Foundation

enum JSON: Codable, Hashable, Sendable, ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral {
    case object([String: JSON])
    case array([JSON])
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case null

    init(stringLiteral value: String) { self = .string(value) }
    init(dictionaryLiteral entries: (String, JSON)...) {
        self = .object(Dictionary(uniqueKeysWithValues: entries))
    }

    subscript(key: String) -> JSON? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]
    }

    var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var array: [JSON]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var integer: Int? {
        guard case .integer(let value) = self else { return nil }
        return value
    }

    var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    var rpcID: Bool {
        switch self {
        case .integer, .string: true
        default: false
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    static func request(_ method: String, id: JSON, params: JSON) -> JSON {
        ["jsonrpc": "2.0", "id": id, "method": .string(method), "params": params]
    }

    static func notification(_ method: String, params: JSON) -> JSON {
        ["jsonrpc": "2.0", "method": .string(method), "params": params]
    }

    static func reply(_ id: JSON, result: JSON) -> JSON {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func failure(_ id: JSON, code: Int, message: String) -> JSON {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .integer(code), "message": .string(message)]]
    }
}
