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
    case double(Double)
    case bool(Bool)

    var wireText: String {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        }
    }

    var jsonValue: Any {
        switch self {
        case .string(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        }
    }

    var transportValue: LuxoValue {
        switch self {
        case .string(let value): return .string(value)
        case .int(let value): return .int(Int64(value))
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
        self.jsonParameters = JSONParameterPlan(params: params, types: types)
    }
}

private struct SelectedField {
    let name: String
    let children: [SelectedField]?
}

private final class SelectionParser {
    private let input: [UInt8]
    private var offset = 0

    init(_ selection: String) {
        input = Array(selection.utf8)
    }

    func parse() throws -> [SelectedField] {
        let fields = try parseList(nested: false, depth: 0)
        skipSpaces()
        if offset != input.count { throw error("unexpected character") }
        return fields
    }

    private func parseList(nested: Bool, depth: Int) throws -> [SelectedField] {
        if depth >= 32 { throw error("selection depth exceeds 32") }
        var fields: [SelectedField] = []
        var names = Set<String>()
        while true {
            skipSpaces()
            if offset >= input.count || (nested && input[offset] == 125) { break }
            let name = readIdentifier()
            if name.isEmpty { throw error("expected field name") }
            if !names.insert(name).inserted { throw error("duplicate field '\(name)'") }
            skipSpaces()
            let children = try readChildren(name: name, depth: depth)
            fields.append(SelectedField(name: name, children: children))
            skipSpaces()
            if offset >= input.count || input[offset] != 44 { break }
            offset += 1
            skipSpaces()
            if offset >= input.count || (nested && input[offset] == 125) {
                throw error("expected field after ','")
            }
        }
        return fields
    }

    private func readChildren(name: String, depth: Int) throws -> [SelectedField]? {
        guard offset < input.count, input[offset] == 123 else { return nil }
        offset += 1
        let children = try parseList(nested: true, depth: depth + 1)
        if children.isEmpty { throw error("empty selection for '\(name)'") }
        skipSpaces()
        guard offset < input.count, input[offset] == 125 else {
            throw error("missing '}' for '\(name)'")
        }
        offset += 1
        return children
    }

    private func readIdentifier() -> String {
        let start = offset
        guard offset < input.count, isIdentifierStart(input[offset]) else { return "" }
        offset += 1
        while offset < input.count, isIdentifierPart(input[offset]) { offset += 1 }
        return String(decoding: input[start..<offset], as: UTF8.self)
    }

    private func skipSpaces() {
        while offset < input.count,
            input[offset] == 32 || input[offset] == 9 || input[offset] == 10 || input[offset] == 13
        {
            offset += 1
        }
    }

    private func error(_ message: String) -> LuxoError {
        LuxoError(code: 0, message: "\(message) at position \(offset)", name: "ConfigError")
    }
}

private func isIdentifierStart(_ byte: UInt8) -> Bool {
    byte == 95 || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
}

private func isIdentifierPart(_ byte: UInt8) -> Bool {
    isIdentifierStart(byte) || (byte >= 48 && byte <= 57)
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

    private static func writeFieldMask(
        _ encoder: inout Encoder,
        schema: APISchema,
        selection: String?
    ) throws {
        guard !schema.fields.isEmpty else {
            encoder.writeVarint(0)
            return
        }
        guard let selection, !selection.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw configError("$select is required for structured responses")
        }
        let selected = try SelectionParser(selection).parse()
        let mask = try encodeSelectionNode(selected, fields: schema.fields, types: schema.types)
        encoder.writeVarint(UInt64(mask.count))
        encoder.writeRawBytes(mask)
    }

    private static func encodeSelectionNode(
        _ selected: [SelectedField],
        fields: [String: APISchema.SelectionFieldSchema],
        types: [String: [String: APISchema.SelectionFieldSchema]]
    ) throws -> Data {
        var fieldMask: [UInt8] = []
        var children: [(fieldID: Int, data: Data)] = []
        for field in selected {
            guard let metadata = fields[field.name] else {
                throw configError("unknown selected field: \(field.name)")
            }
            try fieldMaskSet(&fieldMask, fieldID: metadata.fieldID)
            guard let childSelection = field.children else { continue }
            guard let typeName = metadata.typeName, let nestedFields = types[typeName] else {
                throw configError("field \(field.name) does not support nested selection")
            }
            children.append(
                (
                    metadata.fieldID,
                    try encodeSelectionNode(
                        childSelection,
                        fields: nestedFields,
                        types: types
                    )
                ))
        }
        var encoder = Encoder()
        encoder.writeVarint(UInt64(fieldMask.count))
        encoder.writeRawBytes(Data(fieldMask))
        for child in children.sorted(by: { $0.fieldID < $1.fieldID }) {
            encoder.writeVarint(UInt64(child.fieldID))
            encoder.writeVarint(UInt64(child.data.count))
            encoder.writeRawBytes(child.data)
        }
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

// MARK: - URLSession Transport (HTTP/2)

/// HTTP/2 transport using URLSession. Single connection, multiplexed requests.
/// Supports both JSON and binary (Luxo codec) modes.
/// Supports timeout configuration and 401 auto-refresh.
public final class URLSessionTransport: Transport, @unchecked Sendable {
    private struct HTTPFailure: Error {
        let statusCode: Int
        let error: LuxoError
    }

    private struct State {
        let headers: [String: String]
        let mode: TransportMode
        let schema: [String: APISchema]
    }

    private let endpoint: URL
    private let session: URLSession
    private let lock = NSLock()
    private var headers: [String: String] = [:]
    private var mode: TransportMode = .json
    private var schema: [String: APISchema] = [:]
    private let timeout: TimeInterval
    private var tokenExpiredHandler: (() async -> String?)?

    /// Called only when HTTP status and the validated error code are both 401.
    /// Return a new token to retry once, or nil to propagate the original error.
    public var onTokenExpired: (() async -> String?)? {
        get { lock.withLock { tokenExpiredHandler } }
        set { lock.withLock { tokenExpiredHandler = newValue } }
    }

    public convenience init(
        endpoint: String,
        token: String? = nil,
        timeout: TimeInterval = 30
    ) throws {
        // HTTP/2 multiplexing via shared URLSession
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["Content-Type": "application/json"]
        try self.init(
            endpoint: endpoint,
            token: token,
            timeout: timeout,
            session: URLSession(configuration: config)
        )
    }

    init(
        endpoint: String,
        token: String? = nil,
        timeout: TimeInterval = 30,
        session: URLSession
    ) throws {
        self.endpoint = try validatedURL(endpoint, schemes: ["http", "https"])
        guard timeout > 0 else {
            throw LuxoError(code: 0, message: "timeout must be greater than zero", name: "ConfigError")
        }
        self.timeout = timeout
        self.session = session
        if let token = token {
            headers["Authorization"] = "Bearer \(token)"
        }
    }

    public func setToken(_ token: String) {
        lock.withLock { headers["Authorization"] = "Bearer \(token)" }
    }

    public func setMode(_ mode: TransportMode) {
        lock.withLock { self.mode = mode }
    }

    public func setSchema(_ schema: [String: APISchema]) throws {
        try validateRuntimeSchemaIDs(schema)
        lock.withLock { self.schema = schema }
    }

    public func call(_ api: String, params: [String: LuxoValue]? = nil) async throws -> TransportPayload {
        do {
            return try await doCall(api, params: params)
        } catch let failure as HTTPFailure {
            let error = failure.error
            guard failure.statusCode == 401, error.code == 401, error.name != "ParseError" else {
                throw error
            }
            let refresh = lock.withLock { tokenExpiredHandler }
            if let refresh, let newToken = await refresh() {
                setToken(newToken)
                do {
                    return try await doCall(api, params: params)
                } catch let retryFailure as HTTPFailure {
                    throw retryFailure.error
                }
            }
            throw error
        }
    }

    private func doCall(_ api: String, params: [String: LuxoValue]?) async throws -> TransportPayload {
        let state = lock.withLock {
            State(headers: headers, mode: mode, schema: schema)
        }
        let data: Data
        switch state.mode {
        case .json:
            data = try await jsonCall(
                api, params: params, headers: state.headers, plan: state.schema[api]?.jsonParameters)
        case .binary:
            data = try await binaryCall(
                api,
                params: params,
                headers: state.headers,
                schema: state.schema
            )
        }
        return TransportPayload(data: data, mode: state.mode)
    }

    private func jsonCall(
        _ api: String,
        params: [String: LuxoValue]?,
        headers: [String: String],
        plan: JSONParameterPlan?
    ) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try LuxoJSONRequest.encode(api: api, params: params, plan: plan)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LuxoError(code: 0, message: "Invalid response")
        }

        let envelope = try decodeJSONEnvelope(data, statusCode: httpResponse.statusCode)
        if httpResponse.statusCode != 200 || envelope.fields["error"] != nil {
            throw HTTPFailure(
                statusCode: httpResponse.statusCode,
                error: JSONEnvelope.decodeError(envelope, statusCode: httpResponse.statusCode))
        }
        return envelope.responseData
    }

    private func decodeJSONEnvelope(_ data: Data, statusCode: Int) throws -> JSONEnvelope {
        do {
            return try JSONEnvelope.decode(data, errorResponse: statusCode != 200)
        } catch {
            throw LuxoError(code: statusCode, message: "invalid JSON response", name: "ParseError")
        }
    }

    private func binaryCall(
        _ api: String,
        params: [String: LuxoValue]?,
        headers: [String: String],
        schema: [String: APISchema]
    ) async throws -> Data {
        guard let apiSchema = schema[api] else {
            throw LuxoError(
                code: 0,
                message: "no schema for API \"\(api)\" — binary mode requires schema",
                name: "ConfigError"
            )
        }
        let body = try LuxoBinaryProtocol.encodeRequest(schema: apiSchema, params: params)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/x-luxo", forHTTPHeaderField: "Content-Type")
        request.setValue("binary", forHTTPHeaderField: "X-Luxo-Mode")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = body

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LuxoError(code: 0, message: "Invalid response", name: "NetworkError")
        }
        guard httpResponse.statusCode == 200 else {
            throw HTTPFailure(
                statusCode: httpResponse.statusCode,
                error: LuxoBinaryProtocol.decodeError(data, statusCode: httpResponse.statusCode))
        }

        return data  // Return raw bytes for binary decoding
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
