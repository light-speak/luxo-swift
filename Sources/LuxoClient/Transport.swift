import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - Transport Protocol

/// Raw response bytes and their encoding, independent of later transport configuration.
public struct TransportPayload: Sendable {
    public let data: Data
    public let mode: TransportMode

    public init(data: Data, mode: TransportMode) {
        self.data = data
        self.mode = mode
    }
}

/// Optional terminal notifications; an explicit cancellation is silent.
public final class StreamObserver: Sendable {
    public let onComplete: (@Sendable () -> Void)?
    public let onError: (@Sendable (LuxoError) -> Void)?

    public init(
        onComplete: (@Sendable () -> Void)? = nil,
        onError: (@Sendable (LuxoError) -> Void)? = nil
    ) {
        self.onComplete = onComplete
        self.onError = onError
    }
}

/// Transport protocol — all transports implement this.
public protocol Transport: Sendable {
    func call(_ api: String, params: [String: LuxoValue]?) async throws -> TransportPayload
    func call(_ api: String, request: any GeneratedRequest) async throws -> TransportPayload
    func subscribe<Value: Sendable>(
        _ api: String, decoder: @escaping @Sendable (TransportPayload) throws -> Value,
        request: any GeneratedRequest, observer: StreamObserver?,
        handler: @escaping @Sendable (Value) -> Void
    ) async throws -> (@Sendable () -> Void)
    func subscribe<Value: Sendable>(
        _ api: String,
        decoder: @escaping @Sendable (TransportPayload) throws -> Value,
        params: [String: LuxoValue]?,
        observer: StreamObserver?,
        handler: @escaping @Sendable (Value) -> Void
    ) async throws -> (@Sendable () -> Void)
    func setToken(_ token: String)
    func setMode(_ mode: TransportMode)
    func setSchema(_ schema: [String: APISchema]) throws
}

public extension Transport {
    func call(_ api: String, request: any GeneratedRequest) async throws -> TransportPayload {
        throw LuxoError(code: 0, message: "transport must implement generated requests", name: "ConfigError")
    }

    func subscribe<Value: Sendable>(
        _ api: String, decoder: @escaping @Sendable (TransportPayload) throws -> Value,
        request: any GeneratedRequest, observer: StreamObserver?,
        handler: @escaping @Sendable (Value) -> Void
    ) async throws -> (@Sendable () -> Void) {
        throw LuxoError(code: 0, message: "transport must implement generated subscriptions", name: "ConfigError")
    }
    func subscribe<Value: Sendable>(
        _ api: String,
        decoder: @escaping @Sendable (TransportPayload) throws -> Value,
        params: [String: LuxoValue]? = nil,
        handler: @escaping @Sendable (Value) -> Void
    ) async throws -> (@Sendable () -> Void) {
        try await subscribe(api, decoder: decoder, params: params, observer: nil, handler: handler)
    }

    func subscribe<Value: Sendable>(
        _ api: String,
        decoder: @escaping @Sendable (TransportPayload) throws -> Value,
        observer: StreamObserver?,
        handler: @escaping @Sendable (Value) -> Void
    ) async throws -> (@Sendable () -> Void) {
        try await subscribe(api, decoder: decoder, params: nil, observer: observer, handler: handler)
    }

    func subscribe<Value: Sendable>(
        _ api: String,
        decoder: @escaping @Sendable (TransportPayload) throws -> Value,
        params: [String: LuxoValue]?,
        observer: StreamObserver?,
        handler: @escaping @Sendable (Value) -> Void
    ) async throws -> (@Sendable () -> Void) {
        throw LuxoError(
            code: 0,
            message: "transport does not support subscriptions",
            name: "ConfigError"
        )
    }
}

public enum TransportMode: String, Sendable {
    case json
    case binary
}

public enum LuxoFilterValue: Sendable {
    case string(String)
    case int(Int)
    case int64(Int64)
    case double(Double)
    case bool(Bool)

    var wireText: String {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .int64(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        }
    }

    var jsonValue: Any {
        switch self {
        case .string(let value): return value
        case .int(let value): return value
        case .int64(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        }
    }

    var transportValue: LuxoValue {
        switch self {
        case .string(let value): return .string(value)
        case .int(let value): return .int(Int64(value))
        case .int64(let value): return .int(value)
        case .double(let value): return .float(value)
        case .bool(let value): return .bool(value)
        }
    }
}

public struct LuxoFilter: Sendable {
    public let field: String
    public let op: String
    public let value: LuxoFilterValue

    public init(field: String, op: String, value: LuxoFilterValue) {
        self.field = field
        self.op = op
        self.value = value
    }

    public var jsonObject: [String: Any] {
        ["field": field, "op": op, "value": value.jsonValue]
    }

    public var transportValue: LuxoValue {
        .object(["field": .string(field), "op": .string(op), "value": value.transportValue])
    }
}

public struct LuxoSorter: Sendable {
    public let field: String
    public let order: String

    public init(field: String, order: String) {
        self.field = field
        self.order = order
    }

    public var jsonObject: [String: Any] {
        ["field": field, "order": order]
    }

    public var transportValue: LuxoValue {
        .object(["field": .string(field), "order": .string(order)])
    }
}

/// API schema metadata for binary encoding and exact JSON parameter validation.
public struct APISchema: Sendable {
    public let id: Int
    public let params: [ParamSchema]?
    public let fields: [String: SelectionFieldSchema]
    public let types: [String: [String: SelectionFieldSchema]]
    let jsonParameters: JSONParameterPlan?
    let selectionIdentity: SelectionSchemaIdentity?

    public struct SelectionFieldSchema: Sendable {
        public let fieldID: Int
        public let typeName: String?
        public let type: String?
        public let isList: Bool
        public let nullable: Bool

        public init(
            fieldID: Int,
            typeName: String? = nil,
            type: String? = nil,
            isList: Bool = false,
            nullable: Bool = false
        ) {
            self.fieldID = fieldID
            self.typeName = typeName
            self.type = type
            self.isList = isList
            self.nullable = nullable
        }
    }

    public struct ParamSchema: Sendable {
        public let fieldID: Int
        public let name: String
        public let type: String
        public let typeName: String?
        public let isList: Bool
        public let nullable: Bool

        public init(
            fieldID: Int,
            name: String,
            type: String,
            typeName: String? = nil,
            isList: Bool = false,
            nullable: Bool = false
        ) {
            self.fieldID = fieldID
            self.name = name
            self.type = type
            self.typeName = typeName
            self.isList = isList
            self.nullable = nullable
        }
    }

    public init(
        id: Int,
        params: [ParamSchema]? = nil,
        fields: [String: SelectionFieldSchema] = [:],
        types: [String: [String: SelectionFieldSchema]] = [:]
    ) {
        self.id = id
        self.params = params
        self.fields = fields
        self.types = types
        self.selectionIdentity = fields.isEmpty ? nil : SelectionSchemaIdentity()
        self.jsonParameters = JSONParameterPlan(params: params, types: types)
    }
}

enum LuxoBinaryProtocol {
    static let filtersFieldID: UInt64 = 0x7ffffffe
    static let sortersFieldID: UInt64 = 0x7fffffff
    static let filterOperatorIDs = [
        "eq": 1, "ne": 2, "gt": 3, "gte": 4, "lt": 5, "lte": 6,
        "contains": 7, "startswith": 8, "endswith": 9, "match": 10,
    ]
    static let callRequest: UInt64 = 0x01
    static let callSuccess: UInt64 = 0x02
    static let callError: UInt64 = 0x03
    static let subscribe: UInt64 = 0x10
    static let unsubscribe: UInt64 = 0x11
    static let stream: UInt64 = 0x12
    static let subscribeSuccess: UInt64 = 0x13
    static let subscribeError: UInt64 = 0x14
    static let streamComplete: UInt64 = 0x15
    static let streamError: UInt64 = 0x16

    static func encodeRequest(schema: APISchema, request: any GeneratedRequest) throws -> Data {
        guard schema.id == request.apiID else {
            throw LuxoError(
                code: 0, message: "generated request API ID differs from registered schema", name: "ConfigError")
        }
        var encoder = Encoder()
        encoder.writeVarint(UInt64(request.apiID))
        try writeFieldMask(&encoder, schema: schema, selection: request.selection, plan: request.selectionPlan)
        try request.writeParameters(to: &encoder)
        if let filters = request.filters { try encodeTypedFilters(&encoder, values: filters) }
        if let sorters = request.sorters { try encodeTypedSorters(&encoder, values: sorters) }
        encoder.writeEnd()
        return encoder.data
    }

    static func encodeRequest(schema: APISchema, params: [String: LuxoValue]?) throws -> Data {
        var encoder = Encoder()
        encoder.writeVarint(UInt64(schema.id))
        let selection: String?
        if case .string(let value) = params?["$select"] {
            selection = value
        } else {
            selection = nil
        }
        try writeFieldMask(&encoder, schema: schema, selection: selection)
        if let params, let paramSchemas = schema.params {
            for param in paramSchemas {
                guard params.keys.contains(param.name), let value = params[param.name] else { continue }
                encoder.writeVarint(UInt64(param.fieldID))
                if param.nullable {
                    if value == .null {
                        encoder.writeBool(false)
                        continue
                    }
                    encoder.writeBool(true)
                } else if value == .null {
                    throw LuxoError(code: 0, message: "parameter \(param.name) is not nullable", name: "ConfigError")
                }
                if param.isList {
                    guard case .array(let values) = value else {
                        throw LuxoError(code: 0, message: "parameter \(param.name) must be a list", name: "ConfigError")
                    }
                    try encodeList(&encoder, param: param, values: values)
                } else {
                    try encodeScalar(&encoder, param: param, value: value)
                }
            }
        }
        if let filters = params?["$filters"] { try encodeFilters(&encoder, value: filters) }
        if let sorters = params?["$sorters"] { try encodeSorters(&encoder, value: sorters) }
        encoder.writeEnd()
        return encoder.data
    }

    static func callFrame(sequence: UInt64, body: Data) -> Data {
        frame(type: callRequest, id: sequence, payload: body)
    }

    static func subscribeFrame(sequence: UInt64, body: Data) -> Data {
        frame(type: subscribe, id: sequence, payload: body)
    }

    static func unsubscribeFrame(sequence: UInt64) -> Data {
        frame(type: unsubscribe, id: sequence, payload: Data())
    }

    private static func frame(type: UInt64, id: UInt64, payload: Data) -> Data {
        var encoder = Encoder()
        encoder.writeVarint(type)
        encoder.writeVarint(id)
        encoder.writeRawBytes(payload)
        return encoder.data
    }

    private static func configError(_ message: String) -> LuxoError {
        LuxoError(code: 0, message: message, name: "ConfigError")
    }

    private static func encodeFilters(_ encoder: inout Encoder, value: LuxoValue) throws {
        guard case .array(let values) = value, values.count <= 1000 else {
            throw configError("$filters must contain at most 1000 entries")
        }
        encoder.writeVarint(filtersFieldID)
        encoder.writeVarint(UInt64(values.count))
        for (index, item) in values.enumerated() {
            guard let filter = filterParts(item), !filter.field.isEmpty,
                let operatorID = filterOperatorIDs[filter.op]
            else {
                throw configError("invalid $filters entry at index \(index)")
            }
            encoder.writeString(filter.field)
            encoder.writeVarint(UInt64(operatorID))
            encoder.writeString(filter.value)
        }
    }

    private static func encodeTypedFilters(_ encoder: inout Encoder, values: [LuxoFilter]) throws {
        guard values.count <= 1000 else { throw configError("$filters must contain at most 1000 entries") }
        encoder.writeVarint(filtersFieldID)
        encoder.writeVarint(UInt64(values.count))
        for (index, filter) in values.enumerated() {
            guard !filter.field.isEmpty, let operatorID = filterOperatorIDs[filter.op] else {
                throw configError("invalid $filters entry at index \(index)")
            }
            if case .double(let value) = filter.value, !value.isFinite {
                throw configError("invalid $filters entry at index \(index)")
            }
            encoder.writeString(filter.field)
            encoder.writeVarint(UInt64(operatorID))
            encoder.writeString(filter.value.wireText)
        }
    }

    private static func encodeTypedSorters(_ encoder: inout Encoder, values: [LuxoSorter]) throws {
        guard values.count <= 100 else { throw configError("$sorters must contain at most 100 entries") }
        encoder.writeVarint(sortersFieldID)
        encoder.writeVarint(UInt64(values.count))
        for (index, sorter) in values.enumerated() {
            guard !sorter.field.isEmpty, sorter.order == "asc" || sorter.order == "desc" else {
                throw configError("invalid $sorters entry at index \(index)")
            }
            encoder.writeString(sorter.field)
            encoder.writeBool(sorter.order == "desc")
        }
    }

    private static func encodeSorters(_ encoder: inout Encoder, value: LuxoValue) throws {
        guard case .array(let values) = value, values.count <= 100 else {
            throw configError("$sorters must contain at most 100 entries")
        }
        encoder.writeVarint(sortersFieldID)
        encoder.writeVarint(UInt64(values.count))
        for (index, item) in values.enumerated() {
            guard let sorter = sorterParts(item), !sorter.field.isEmpty,
                sorter.order == "asc" || sorter.order == "desc"
            else {
                throw configError("invalid $sorters entry at index \(index)")
            }
            encoder.writeString(sorter.field)
            encoder.writeBool(sorter.order == "desc")
        }
    }

    private static func filterParts(_ value: LuxoValue) -> (field: String, op: String, value: String)? {
        guard case .object(let item) = value,
            case .string(let field) = item["field"],
            case .string(let op) = item["op"],
            let raw = item["value"],
            let text = filterValueText(raw)
        else {
            return nil
        }
        return (field, op, text)
    }

    private static func sorterParts(_ value: LuxoValue) -> (field: String, order: String)? {
        guard case .object(let item) = value,
            case .string(let field) = item["field"],
            case .string(let order) = item["order"]
        else { return nil }
        return (field, order)
    }

    private static func filterValueText(_ value: LuxoValue) -> String? {
        switch value {
        case .string(let value): return value
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .float(let value): return value.isFinite ? String(value) : nil
        default: return nil
        }
    }

    private static func encodeScalar(
        _ encoder: inout Encoder,
        param: APISchema.ParamSchema,
        value: LuxoValue
    ) throws {
        try encodeValue(&encoder, type: param.type, value: value)
    }

    private static func encodeList(
        _ encoder: inout Encoder,
        param: APISchema.ParamSchema,
        values: [LuxoValue]
    ) throws {
        encoder.writeVarint(UInt64(values.count))
        for value in values {
            try encodeValue(&encoder, type: param.type, value: value)
        }
    }

    private static func encodeValue(_ encoder: inout Encoder, type: String, value: LuxoValue) throws {
        switch type {
        case "Int", "Duration":
            guard case .int(let number) = value else { throw invalidValue(type) }
            encoder.writeSvarint(number)
        case "Float":
            switch value {
            case .float(let number): try encoder.writeFixed64(number)
            case .int(let number): try encoder.writeFixed64(Double(number))
            default: throw invalidValue(type)
            }
        case "String", "Enum", "Decimal":
            guard case .string(let string) = value else { throw invalidValue(type) }
            encoder.writeString(string)
        case "Boolean":
            guard case .bool(let boolean) = value else { throw invalidValue(type) }
            encoder.writeBool(boolean)
        case "DateTime":
            guard case .string(let text) = value else { throw invalidValue(type) }
            try encoder.writeDateTime(text)
        case "UUID":
            if case .string(let string) = value, let uuid = UUID(uuidString: string) {
                encoder.writeUUID(uuid)
            } else {
                throw invalidValue(type)
            }
        case "Bytes":
            switch value {
            case .bytes(let bytes): encoder.writeBytes(bytes)
            case .string(let text):
                guard let bytes = Data(base64Encoded: text) else { throw invalidValue(type) }
                encoder.writeBytes(bytes)
            default: throw invalidValue(type)
            }
        case "JSON":
            encoder.writeBytes(try value.jsonData())
        case "Model":
            guard case .structured(let value) = value else { throw invalidValue(type) }
            try encoder.writeDelimited { try value.writeLuxo(to: &$0) }
        default:
            throw LuxoError(code: 0, message: "unsupported binary param type: \(type)", name: "ConfigError")
        }
    }

    private static func invalidValue(_ type: String) -> LuxoError {
        LuxoError(code: 0, message: "invalid \(type) parameter", name: "ConfigError")
    }
}

func validatedURL(_ value: String, schemes: Set<String>) throws -> URL {
    guard let url = URL(string: value),
        let scheme = url.scheme?.lowercased(),
        schemes.contains(scheme),
        url.host != nil
    else {
        throw LuxoError(code: 0, message: "invalid transport URL: \(value)", name: "ConfigError")
    }
    return url
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
