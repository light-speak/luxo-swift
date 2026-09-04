import Foundation

/// Three-state argument for patch APIs: absent, explicit null, or a value.
public enum LuxoOptional<Value> {
    case absent
    case present(Value?)
}

/// A field-selected output value.
///
/// `unselected` means the server did not return the field. For nullable
/// fields, `value(nil)` represents a field that was selected and returned null.
public enum Selected<Value: Sendable>: Sendable {
    case unselected
    case value(Value)

    /// Returns the selected value or throws when the field was not requested.
    public func requireValue() throws -> Value {
        switch self {
        case .unselected:
            throw LuxoError(code: 0, message: "field was not selected", name: "SelectionError")
        case .value(let value):
            return value
        }
    }
}

extension Selected: Codable where Value: Codable {
    public init(from decoder: Swift.Decoder) throws {
        self = .value(try decoder.singleValueContainer().decode(Value.self))
    }

    public func encode(to encoder: Swift.Encoder) throws {
        switch self {
        case .unselected:
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "unselected fields must be omitted")
            )
        case .value(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }
    }
}

public extension KeyedDecodingContainer {
    func decode<Value>(
        _ type: Selected<Value>.Type,
        forKey key: Key
    ) throws -> Selected<Value> where Value: Codable & Sendable {
        guard contains(key) else { return .unselected }
        return .value(try decode(Value.self, forKey: key))
    }
}

public extension KeyedEncodingContainer {
    mutating func encode<Value>(
        _ selected: Selected<Value>,
        forKey key: Key
    ) throws where Value: Codable & Sendable {
        guard case .value(let value) = selected else { return }
        try encode(value, forKey: key)
    }
}

/// Codable, Sendable representation of an arbitrary JSON value.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Swift.Encoder) throws {
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
}

// MARK: - Pagination

/// Offset-based page response.
public struct Page<T: Decodable>: Decodable {
    public let items: [T]
    public let total: Int
    public let page: Int
    public let pageSize: Int

    public init(items: [T], total: Int, page: Int, pageSize: Int) {
        self.items = items
        self.total = total
        self.page = page
        self.pageSize = pageSize
    }
}

/// Cursor-based page response.
public struct Cursor<T: Decodable>: Decodable {
    public let items: [T]
    public let nextCursor: String?
    public let hasMore: Bool
}

// MARK: - Schema (for codegen / introspection)

public struct LuxoSchema: Codable, Sendable {
    public let models: [String: LuxoModel]
    public let apis: [String: LuxoAPI]
    public let enums: [String: LuxoEnum]?
    public let types: [String: LuxoTypeDecl]?
}

public struct LuxoEnum: Codable, Sendable {
    public let name: String
    public let values: [String]
}

public enum TypeUsage: String, Codable, Sendable {
    case input
    case output
    case inputOutput
    case unused
}

public struct LuxoTypeDecl: Codable, Sendable {
    public let name: String
    public let usage: TypeUsage?
    public let fields: [LuxoField]

    public init(name: String, usage: TypeUsage? = nil, fields: [LuxoField]) {
        self.name = name
        self.usage = usage
        self.fields = fields
    }
}

public struct LuxoModel: Codable, Sendable {
    public let name: String
    public let usage: TypeUsage?
    public let fields: [LuxoField]

    public init(name: String, usage: TypeUsage? = nil, fields: [LuxoField]) {
        self.name = name
        self.usage = usage
        self.fields = fields
    }
}

public struct LuxoField: Codable, Sendable {
    public let id: Int
    public let name: String
    public let type: String
    public let typeName: String?
    public let nullable: Bool?
    public let isList: Bool?
    public let relation: Bool?
}

public struct LuxoAPI: Codable, Sendable {
    public let id: Int
    public let name: String
    public let module: String
    public let returnType: String?
    public let returnList: Bool?
    public let paginated: Bool?
    public let stream: Bool?
    public let params: [LuxoParam]?
}

public struct LuxoParam: Codable, Sendable {
    public let id: Int
    public let name: String
    public let type: String
    public let typeName: String?
    public let nullable: Bool?
    public let hasDefault: Bool?
    public let isList: Bool?
}
