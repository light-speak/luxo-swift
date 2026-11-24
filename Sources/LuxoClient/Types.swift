import Foundation

/// Three-state argument for patch APIs: absent, explicit null, or a value.
public enum LuxoOptional<Value> {
    case absent
    case present(Value?)
}

extension LuxoOptional: Sendable where Value: Sendable {}

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
    /// Records projection presence during the existing field read, including explicit null.
    @inlinable
    func decode<Value>(
        _ type: Selected<Value>.Type, forKey key: Key, selected: inout Bool
    ) throws -> Selected<Value> where Value: Codable & Sendable {
        guard contains(key) else { return .unselected }
        let value = try decode(Value.self, forKey: key)
        selected = true
        return .value(value)
    }

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
    case integer(Int64)
    case number(Double)
    case rawNumber(JSONNumber)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONValue(JSONReader.decode(data))
    }

    /// Binary JSON fields do not permit a document encoding marker.
    public static func parseBinary(_ data: Data) throws -> JSONValue {
        try JSONValue(JSONReader.decode(data, allowDocumentBOM: false))
    }

    public func jsonData() throws -> Data { try LuxoValue.checkedJSON(self).jsonData() }

    init(_ value: LuxoValue, depth: Int = 0) throws {
        switch value {
        case .null: self = .null
        case .bool(let value): self = .bool(value)
        case .int(let value): self = .integer(value)
        case .float(let value): self = .number(value)
        case .jsonNumber(let value): self = .rawNumber(value)
        case .string(let value): self = .string(value)
        case .array(let values):
            try requireJSONContainerDepth(depth, name: "DecodingError")
            self = .array(try values.map { try JSONValue($0, depth: depth + 1) })
        case .object(let values):
            try requireJSONContainerDepth(depth, name: "DecodingError")
            self = .object(try values.mapValues { try JSONValue($0, depth: depth + 1) })
        case .json(let value):
            try value.validateDepth(depth, name: "DecodingError")
            self = value
        case .bytes, .structured:
            throw LuxoError(code: 0, message: "not a JSON value", name: "DecodingError")
        }
    }

    fileprivate func validateDepth(_ depth: Int, name: String) throws {
        switch self {
        case .array(let values):
            try requireJSONContainerDepth(depth, name: name)
            for value in values { try value.validateDepth(depth + 1, name: name) }
        case .object(let values):
            try requireJSONContainerDepth(depth, name: name)
            for value in values.values { try value.validateDepth(depth + 1, name: name) }
        default: break
        }
    }

    fileprivate func transportEquals(_ other: LuxoValue) -> Bool {
        switch (self, other) {
        case (.null, .null), (.null, .json(.null)): return true
        case (.bool(let a), .bool(let b)), (.bool(let a), .json(.bool(let b))): return a == b
        case (.integer(let a), .int(let b)), (.integer(let a), .json(.integer(let b))): return a == b
        case (.number(let a), .float(let b)), (.number(let a), .json(.number(let b))): return a == b
        case (.rawNumber(let a), .jsonNumber(let b)), (.rawNumber(let a), .json(.rawNumber(let b))): return a == b
        case (.string(let a), .string(let b)), (.string(let a), .json(.string(let b))): return a == b
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.transportEquals($1) }
        case (.array(let a), .json(.array(let b))):
            return a.count == b.count && zip(a, b).allSatisfy { $0.transportEquals(.json($1)) }
        case (.object(let a), .object(let b)):
            return a.count == b.count && a.allSatisfy { key, value in b[key].map(value.transportEquals) ?? false }
        case (.object(let a), .json(.object(let b))):
            return a.count == b.count
                && a.allSatisfy { key, value in b[key].map { value.transportEquals(.json($0)) } ?? false }
        default: return false
        }
    }

    fileprivate func foundationValue(depth: Int = 0) throws -> Any {
        switch self {
        case .array(let values):
            try requireJSONContainerDepth(depth, name: "EncodingError")
            return try values.map { try $0.foundationValue(depth: depth + 1) }
        case .object(let values):
            try requireJSONContainerDepth(depth, name: "EncodingError")
            return try values.mapValues { try $0.foundationValue(depth: depth + 1) }
        default: return try LuxoValue(self).foundationValue()
        }
    }

    public init(from decoder: Swift.Decoder) throws {
        if let decoder = decoder as? JSONTreeDecoder {
            self = try JSONValue(decoder.value)
            return
        }
        if let decoder = decoder as? JSONCodableDecoder {
            self = try decoder.jsonValue()
            return
        }
        self = try JSONValue.decodeFoundation(from: decoder, depth: 0)
    }

    private static func decodeFoundation(from decoder: Swift.Decoder, depth: Int) throws -> JSONValue {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            return .null
        } else if let value = try? container.decode(Bool.self) {
            return .bool(value)
        } else if let value = try? container.decode(String.self) {
            return .string(value)
        }
        if var array = try? decoder.unkeyedContainer() {
            try requireJSONContainerDepth(depth, name: "DecodingError")
            var values: [JSONValue] = []
            while !array.isAtEnd {
                values.append(try decodeFoundation(from: array.superDecoder(), depth: depth + 1))
            }
            return .array(values)
        }
        let object = try decoder.container(keyedBy: JSONCodingKey.self)
        try requireJSONContainerDepth(depth, name: "DecodingError")
        var values: [String: JSONValue] = [:]
        for key in object.allKeys {
            values[key.stringValue] = try decodeFoundation(from: object.superDecoder(forKey: key), depth: depth + 1)
        }
        return .object(values)
    }

    public func encode(to encoder: Swift.Encoder) throws {
        if let encoder = encoder as? JSONTreeEncoder {
            encoder.node.storage = .value(try LuxoValue.checkedJSON(self))
            return
        }
        try encodeFoundation(to: encoder, depth: 0)
    }

    private func encodeFoundation(to encoder: Swift.Encoder, depth: Int) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .rawNumber:
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "use Luxo JSON encoding to preserve raw number tokens"))
        case .string(let value): try container.encode(value)
        case .array(let values):
            try requireJSONContainerDepth(depth, name: "EncodingError")
            var array = encoder.unkeyedContainer()
            for value in values { try value.encodeFoundation(to: array.superEncoder(), depth: depth + 1) }
        case .object(let values):
            try requireJSONContainerDepth(depth, name: "EncodingError")
            var object = encoder.container(keyedBy: JSONCodingKey.self)
            for (key, value) in values {
                try value.encodeFoundation(
                    to: object.superEncoder(forKey: JSONCodingKey(stringValue: key)), depth: depth + 1)
            }
        }
    }

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.integer(let a), .integer(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.rawNumber(let a), .rawNumber(let b)): return a == b
        case (.integer(let integer), .number(let number)), (.number(let number), .integer(let integer)):
            return Int64(exactly: number) == integer
        case (.string(let a), .string(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)): return a == b
        default: return false
        }
    }
}

/// A generated input value that can write the native Luxo message directly.
public protocol LuxoBinaryEncodable: Encodable, Sendable {
    func writeLuxo(to encoder: inout Encoder) throws
    func luxoJSONValue() throws -> LuxoValue
}

public extension LuxoBinaryEncodable {
    // Preserve custom Encodable conformers; generated inputs supply a typed projection.
    func luxoJSONValue() throws -> LuxoValue {
        try LuxoValue.encode(self)
    }
}

/// Sendable value representation used at transport boundaries.
///
/// Unlike `Any`, this preserves integer precision and makes values safe to move
/// between Swift concurrency domains. Binary payloads remain raw `Data`.
public enum LuxoValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case float(Double)
    case jsonNumber(JSONNumber)
    case string(String)
    case bytes(Data)
    case array([LuxoValue])
    case object([String: LuxoValue])
    case structured(any LuxoBinaryEncodable)
    /// A generic JSON root whose container budget is independent of its enclosing model.
    case json(JSONValue)

    public init(_ value: Int) { self = .int(Int64(value)) }
    public init(_ value: Int64) { self = .int(value) }
    public init(_ value: Double) { self = .float(value) }

    /// Constructs a schema Float without an intermediate JSON round trip.
    public init(finiteFloat value: Double) throws {
        self = .float(try Self.checkedFloat(value))
    }

    private static func checkedFloat(_ value: Double) throws -> Double {
        guard value.isFinite else {
            throw LuxoError(code: 0, message: "non-finite Float parameter", name: "EncodingError")
        }
        return value
    }

    public init(_ value: String) { self = .string(value) }
    public init(_ value: Bool) { self = .bool(value) }
    public init(_ value: Data) { self = .bytes(value) }
    public init(_ value: UUID) { self = .string(value.uuidString) }

    public init(_ value: JSONValue) {
        switch value {
        case .null: self = .null
        case .bool(let value): self = .bool(value)
        case .integer(let value): self = .int(value)
        case .number(let value): self = .float(value)
        case .rawNumber(let value): self = .jsonNumber(value)
        case .string(let value): self = .string(value)
        case .array(let values): self = .array(values.map(LuxoValue.init))
        case .object(let values): self = .object(values.mapValues(LuxoValue.init))
        }
    }

    /// Validate and retain a generic JSON root without copying its value tree.
    public static func checkedJSON(_ value: JSONValue) throws -> LuxoValue {
        try value.validateDepth(0, name: "EncodingError")
        return .json(value)
    }

    public static func encode<Value: Encodable & Sendable>(_ value: Value) throws -> LuxoValue {
        try JSONTreeEncoder.project(value)
    }

    static func decodeJSONData(_ data: Data, allowDocumentBOM: Bool = true) throws -> LuxoValue {
        try JSONReader.decode(data, allowDocumentBOM: allowDocumentBOM)
    }

    func jsonData() throws -> Data {
        try JSONWriter.encode(self)
    }

    func foundationValue() throws -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .float(let value): return try Self.checkedFloat(value)
        case .jsonNumber(let value): return value
        case .string(let value): return value
        case .bytes(let value): return value.base64EncodedString()
        case .array(let values): return try values.map { try $0.foundationValue() }
        case .object(let values): return try values.mapValues { try $0.foundationValue() }
        case .structured(let value): return try value.luxoJSONValue().foundationValue()
        case .json(let value): return try value.foundationValue()
        }
    }

    public static func == (lhs: LuxoValue, rhs: LuxoValue) -> Bool {
        switch (lhs, rhs) {
        case (.json(let value), _): return value.transportEquals(rhs)
        case (_, .json(let value)): return value.transportEquals(lhs)
        case (.null, .null): return true
        case (.bool(let lhs), .bool(let rhs)): return lhs == rhs
        case (.int(let lhs), .int(let rhs)): return lhs == rhs
        case (.float(let lhs), .float(let rhs)): return lhs == rhs
        case (.jsonNumber(let lhs), .jsonNumber(let rhs)): return lhs == rhs
        case (.string(let lhs), .string(let rhs)): return lhs == rhs
        case (.bytes(let lhs), .bytes(let rhs)): return lhs == rhs
        case (.array(let lhs), .array(let rhs)): return lhs == rhs
        case (.object(let lhs), .object(let rhs)): return lhs == rhs
        case (.structured(let lhs), .structured(let rhs)):
            guard let lhs = try? lhs.luxoJSONValue(), let rhs = try? rhs.luxoJSONValue() else { return false }
            return lhs == rhs
        default: return false
        }
    }

}

extension LuxoValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension LuxoValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension LuxoValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension LuxoValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .float(value) }
}

extension LuxoValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension LuxoValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: LuxoValue...) { self = .array(elements) }
}

extension LuxoValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, LuxoValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
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
    public let sealeds: [String: LuxoSealed]?

    public init(
        models: [String: LuxoModel], apis: [String: LuxoAPI], enums: [String: LuxoEnum]? = nil,
        types: [String: LuxoTypeDecl]? = nil, sealeds: [String: LuxoSealed]? = nil
    ) {
        self.models = models
        self.apis = apis
        self.enums = enums
        self.types = types
        self.sealeds = sealeds
    }
}

public struct LuxoSealed: Codable, Sendable {
    public let name: String
    public let module: String?
    public let usage: TypeUsage?
    public let description: String?
    public let variants: [LuxoSealedVariant]
}

public struct LuxoSealedVariant: Codable, Sendable {
    public let id: Int
    public let name: String
    public let fields: [LuxoParam]
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
    public let computedSources: [String: LuxoComputedSource]?

    public init(
        name: String, usage: TypeUsage? = nil, fields: [LuxoField], computedSources: [String: LuxoComputedSource]? = nil
    ) {
        self.name = name
        self.usage = usage
        self.fields = fields
        self.computedSources = computedSources
    }
}

public struct LuxoComputedSource: Codable, Sendable {
    public let model: String
    public let module: String?

    public init(model: String, module: String? = nil) {
        self.model = model
        self.module = module
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
    public let returnNullable: Bool?
    public let paginated: Bool?
    public let stream: Bool?
    public let params: [LuxoParam]?
    public let isInternal: Bool?
    public let query: LuxoQueryCapabilities?

    enum CodingKeys: String, CodingKey {
        case id, name, module, returnType, returnList, returnNullable, paginated, stream, params
        case isInternal = "internal"
        case query
    }

    public init(
        id: Int, name: String, module: String, returnType: String? = nil,
        returnList: Bool? = nil, paginated: Bool? = nil, stream: Bool? = nil,
        params: [LuxoParam]? = nil, isInternal: Bool? = nil, returnNullable: Bool? = nil,
        query: LuxoQueryCapabilities? = nil
    ) {
        self.id = id
        self.name = name
        self.module = module
        self.returnType = returnType
        self.returnList = returnList
        self.returnNullable = returnNullable
        self.paginated = paginated
        self.stream = stream
        self.params = params
        self.isInternal = isInternal
        self.query = query
    }
}

public struct LuxoQueryCapabilities: Codable, Sendable {
    public let filters: [LuxoQueryFilter]?
    public let sorters: [String]?
    public init(filters: [LuxoQueryFilter]? = nil, sorters: [String]? = nil) {
        self.filters = filters
        self.sorters = sorters
    }
}

public struct LuxoQueryFilter: Codable, Sendable {
    public let field: String
    public let type: String
    public let operators: [String]
    public init(field: String, type: String, operators: [String]) {
        self.field = field
        self.type = type
        self.operators = operators
    }
}

public struct LuxoParam: Codable, Sendable {
    public let id: Int
    public let name: String
    public let type: String
    public let typeName: String?
    public let nullable: Bool?
    public let hasDefault: Bool?
    public let isList: Bool?
    public let description: String?

    public init(
        id: Int, name: String, type: String, typeName: String? = nil,
        nullable: Bool? = nil, hasDefault: Bool? = nil, isList: Bool? = nil, description: String? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.typeName = typeName
        self.nullable = nullable
        self.hasDefault = hasDefault
        self.isList = isList
        self.description = description
    }
}
