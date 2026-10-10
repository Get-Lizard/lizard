import Foundation

/// JSON as it comes from the extension host (kept separate from AIEngine's JSONValue so this
/// module has no AI dependency).
public enum HostJSON: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([HostJSON])
    case object([String: HostJSON])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([HostJSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: HostJSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> HostJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var string: String? {
        switch self {
        case .string(let value): value
        case .number(let value): value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value): String(value)
        default: nil
        }
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var array: [HostJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var object: [String: HostJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool { self == .null }

    /// The callback id of a serialized function prop (`{"$callback": "12.onAction"}`).
    public var callbackID: String? { self["$callback"]?.string }

    public init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let value as Bool: self = .bool(value)
        case let value as Int: self = .number(Double(value))
        case let value as Double: self = .number(value)
        case let value as String: self = .string(value)
        case let value as [Any]: self = .array(value.map { HostJSON(any: $0) })
        case let value as [String: Any]: self = .object(value.mapValues { HostJSON(any: $0) })
        default: self = .string(String(describing: value!))
        }
    }

    public var anyValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let value): value.map(\.anyValue)
        case .object(let value): value.mapValues(\.anyValue)
        }
    }
}
