import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - Transport Protocol

/// Transport protocol — all transports implement this.
public protocol Transport: Sendable {
    func call(_ api: String, params: [String: Any]?) async throws -> Any
    func subscribe(
        _ api: String,
        params: [String: Any]?,
        handler: @escaping (Any) -> Void
    ) async throws -> () -> Void
    func setToken(_ token: String)
    func setMode(_ mode: TransportMode)
    func setSchema(_ schema: [String: APISchema])
}

public extension Transport {
    func subscribe(
        _ api: String,
        params: [String: Any]? = nil,
        handler: @escaping (Any) -> Void
    ) async throws -> () -> Void {
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
}

/// API schema metadata for binary encoding.
public struct APISchema: Sendable {
    public let id: Int
    public let params: [ParamSchema]?
    public let fields: [String: SelectionFieldSchema]
    public let types: [String: [String: SelectionFieldSchema]]

    public struct SelectionFieldSchema: Sendable {
        public let fieldID: Int
        public let typeName: String?

        public init(fieldID: Int, typeName: String? = nil) {
            self.fieldID = fieldID
            self.typeName = typeName
        }
    }

    public struct ParamSchema: Sendable {
        public let fieldID: Int
        public let name: String
        public let type: String
        public let isList: Bool
        public let nullable: Bool

        public init(fieldID: Int, name: String, type: String, isList: Bool = false, nullable: Bool = false) {
            self.fieldID = fieldID
            self.name = name
            self.type = type
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
    static let subscribe: UInt64 = 0x04
    static let unsubscribe: UInt64 = 0x05
    static let stream: UInt64 = 0x06
    static let subscribeSuccess: UInt64 = 0x07
    static let subscribeError: UInt64 = 0x08

    static func encodeRequest(schema: APISchema, params: [String: Any]?) throws -> Data {
        var encoder = Encoder()
        encoder.writeVarint(UInt64(schema.id))
        try writeFieldMask(&encoder, schema: schema, selection: params?["$select"] as? String)
        if let params, let paramSchemas = schema.params {
            for param in paramSchemas {
                guard params.keys.contains(param.name), let value = params[param.name] else { continue }
                encoder.writeVarint(UInt64(param.fieldID))
                if param.nullable {
                    if value is NSNull {
                        encoder.writeBool(false)
                        continue
                    }
                    encoder.writeBool(true)
                } else if value is NSNull {
                    throw LuxoError(code: 0, message: "parameter \(param.name) is not nullable", name: "ConfigError")
                }
                if param.isList {
                    guard let values = value as? [Any] else {
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

    static func subscribeFrame(body: Data) -> Data {
        frame(type: subscribe, id: nil, payload: body)
    }

    static func unsubscribeFrame(apiID: Int) -> Data {
        frame(type: unsubscribe, id: UInt64(apiID), payload: Data())
    }

    static func decodeError(_ data: Data, statusCode: Int) -> LuxoError {
        var decoder = Decoder(data)
        var code = statusCode
        var name = "Error"
        var message = "HTTP \(statusCode)"
        var traceId: String?
        var errorData: Any?
        var cause: String?
        var seen = 0
        var ended = false
        while decoder.remaining > 0 {
            let fieldID = decoder.nextField()
            if fieldID == 0 {
                ended = decoder.error == nil
                break
            }
            switch fieldID {
            case 1:
                code = Int(decoder.readSvarint())
                seen |= 1
            case 2:
                name = decoder.readString()
                seen |= 2
            case 3:
                message = decoder.readString()
                seen |= 4
            case 4: traceId = decoder.readString()
            case 5:
                do {
                    errorData = try JSONSerialization.jsonObject(
                        with: decoder.readBytes(),
                        options: [.fragmentsAllowed]
                    )
                } catch {
                    return binaryParseError(statusCode, "invalid JSON data")
                }
            case 6: cause = decoder.readString()
            default:
                return binaryParseError(statusCode, "unknown binary error field \(fieldID)")
            }
        }
        if let error = decoder.error { return binaryParseError(statusCode, error) }
        if !ended { return binaryParseError(statusCode, "missing end marker") }
        if decoder.remaining != 0 { return binaryParseError(statusCode, "trailing bytes") }
        if seen != 7 { return binaryParseError(statusCode, "missing required fields") }
        return LuxoError(
            code: code,
            message: message,
            name: name,
            traceId: traceId,
            data: errorData,
            cause: cause
        )
    }

    private static func binaryParseError(_ statusCode: Int, _ message: String) -> LuxoError {
        LuxoError(
            code: statusCode,
            message: "invalid binary error response: \(message)",
            name: "ParseError"
        )
    }

    private static func frame(type: UInt64, id: UInt64?, payload: Data) -> Data {
        var encoder = Encoder()
        encoder.writeVarint(type)
        if let id { encoder.writeVarint(id) }
        encoder.writeRawBytes(payload)
        return encoder.data
    }

    private static func writeFieldMask(
        _ encoder: inout Encoder,
        schema: APISchema,
        selection: String?
    ) throws {
        guard let selection, !selection.trimmingCharacters(in: .whitespaces).isEmpty,
            !schema.fields.isEmpty
        else {
            encoder.writeVarint(0)
            return
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
            fieldMaskSet(&fieldMask, fieldID: metadata.fieldID)
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

    private static func encodeFilters(_ encoder: inout Encoder, value: Any) throws {
        guard let values = value as? [Any], values.count <= 1000 else {
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

    private static func encodeSorters(_ encoder: inout Encoder, value: Any) throws {
        guard let values = value as? [Any], values.count <= 100 else {
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

    private static func filterParts(_ value: Any) -> (field: String, op: String, value: String)? {
        if let filter = value as? LuxoFilter {
            if case .double(let number) = filter.value, !number.isFinite { return nil }
            return (filter.field, filter.op, filter.value.wireText)
        }
        guard let item = value as? [String: Any], let field = item["field"] as? String,
            let op = item["op"] as? String, let raw = item["value"], let text = filterValueText(raw)
        else {
            return nil
        }
        return (field, op, text)
    }

    private static func sorterParts(_ value: Any) -> (field: String, order: String)? {
        if let sorter = value as? LuxoSorter { return (sorter.field, sorter.order) }
        guard let item = value as? [String: Any], let field = item["field"] as? String,
            let order = item["order"] as? String
        else { return nil }
        return (field, order)
    }

    private static func filterValueText(_ value: Any) -> String? {
        if let string = value as? String { return string }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            return double.isFinite ? number.stringValue : nil
        }
        return nil
    }

    private static func encodeScalar(
        _ encoder: inout Encoder,
        param: APISchema.ParamSchema,
        value: Any
    ) throws {
        try encodeValue(&encoder, type: param.type, value: value)
    }

    private static func encodeList(
        _ encoder: inout Encoder,
        param: APISchema.ParamSchema,
        values: [Any]
    ) throws {
        encoder.writeVarint(UInt64(values.count))
        for value in values {
            try encodeValue(&encoder, type: param.type, value: value)
        }
    }

    private static func encodeValue(_ encoder: inout Encoder, type: String, value: Any) throws {
        switch type {
        case "Int", "Duration":
            guard let number = value as? NSNumber else { throw invalidValue(type) }
            encoder.writeSvarint(number.int64Value)
        case "Float":
            guard let number = value as? NSNumber else { throw invalidValue(type) }
            encoder.writeFixed64(number.doubleValue)
        case "String", "Enum", "Decimal":
            guard let string = value as? String else { throw invalidValue(type) }
            encoder.writeString(string)
        case "Boolean":
            guard let boolean = value as? Bool else { throw invalidValue(type) }
            encoder.writeBool(boolean)
        case "DateTime":
            encoder.writeSvarint(try unixSeconds(value))
        case "UUID":
            if let uuid = value as? UUID {
                encoder.writeUUID(uuid)
            } else if let string = value as? String, let uuid = UUID(uuidString: string) {
                encoder.writeUUID(uuid)
            } else {
                throw invalidValue(type)
            }
        case "Bytes":
            guard let bytes = value as? Data else { throw invalidValue(type) }
            encoder.writeBytes(bytes)
        case "JSON":
            let bytes: Data
            if let jsonValue = value as? JSONValue {
                bytes = try JSONEncoder().encode(jsonValue)
            } else {
                bytes = try JSONSerialization.data(
                    withJSONObject: value,
                    options: [.fragmentsAllowed, .sortedKeys]
                )
            }
            encoder.writeBytes(bytes)
        default:
            throw LuxoError(code: 0, message: "unsupported binary param type: \(type)", name: "ConfigError")
        }
    }

    private static func unixSeconds(_ value: Any) throws -> Int64 {
        if let text = value as? String,
            let date = ISO8601DateFormatter().date(from: text)
        {
            return Int64(date.timeIntervalSince1970)
        }
        throw invalidValue("DateTime")
    }

    private static func invalidValue(_ type: String) -> LuxoError {
        LuxoError(code: 0, message: "invalid \(type) parameter", name: "ConfigError")
    }
}

enum LuxoWebSocketProtocol {
    struct SubscriptionAcknowledgement {
        let api: String?
        let apiID: UInt64?
        let error: LuxoError?
    }

    static func decodeJSONSubscriptionAcknowledgement(
        _ json: [String: Any]
    ) -> SubscriptionAcknowledgement? {
        guard let api = json["$sub"] as? String else { return nil }
        if json["ok"] as? Bool == true {
            return SubscriptionAcknowledgement(api: api, apiID: nil, error: nil)
        }
        guard json["error"] != nil else { return nil }
        return SubscriptionAcknowledgement(api: api, apiID: nil, error: LuxoError.from(json: json))
    }

    static func decodeBinarySubscriptionAcknowledgement(
        _ data: Data
    ) -> SubscriptionAcknowledgement? {
        var decoder = Decoder(data)
        let frameType = decoder.readVarint()
        guard frameType == LuxoBinaryProtocol.subscribeSuccess || frameType == LuxoBinaryProtocol.subscribeError else {
            return nil
        }
        let apiID = decoder.readVarint()
        let error =
            frameType == LuxoBinaryProtocol.subscribeError
            ? LuxoBinaryProtocol.decodeError(decoder.readRemainingData(), statusCode: 0)
            : nil
        return SubscriptionAcknowledgement(api: nil, apiID: apiID, error: error)
    }
}

// MARK: - URLSession Transport (HTTP/2)

/// HTTP/2 transport using URLSession. Single connection, multiplexed requests.
/// Supports both JSON and binary (Luxo codec) modes.
/// Supports timeout configuration and 401 auto-refresh.
public final class URLSessionTransport: Transport, @unchecked Sendable {
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

    /// Callback invoked on 401 response. Return a new token to retry, or nil to propagate error.
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

    public func setSchema(_ schema: [String: APISchema]) {
        lock.withLock { self.schema = schema }
    }

    public func call(_ api: String, params: [String: Any]? = nil) async throws -> Any {
        do {
            return try await doCall(api, params: params)
        } catch let error as LuxoError where error.code == 401 {
            // Attempt token refresh on 401
            let refresh = lock.withLock { tokenExpiredHandler }
            if let refresh, let newToken = await refresh() {
                setToken(newToken)
                return try await doCall(api, params: params)
            }
            throw error
        }
    }

    private func doCall(_ api: String, params: [String: Any]?) async throws -> Any {
        let state = lock.withLock {
            State(headers: headers, mode: mode, schema: schema)
        }
        switch state.mode {
        case .json:
            return try await jsonCall(api, params: params, headers: state.headers)
        case .binary:
            return try await binaryCall(
                api,
                params: params,
                headers: state.headers,
                schema: state.schema
            )
        }
    }

    private func jsonCall(
        _ api: String,
        params: [String: Any]?,
        headers: [String: String]
    ) async throws -> Any {
        var body: [String: Any] = ["$api": api]
        if let params = params {
            for (k, v) in params { body[k] = v }
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LuxoError(code: 0, message: "Invalid response")
        }

        let json = try decodeJSONEnvelope(data, statusCode: httpResponse.statusCode)
        if httpResponse.statusCode != 200 || json["error"] != nil {
            var error = LuxoError.from(json: json)
            if error.code == 0 {
                error = LuxoError(
                    code: httpResponse.statusCode,
                    message: error.message,
                    name: error.name,
                    traceId: error.traceId,
                    data: error.data,
                    cause: error.cause
                )
            }
            throw error
        }
        return json["data"] ?? NSNull()
    }

    private func decodeJSONEnvelope(_ data: Data, statusCode: Int) throws -> [String: Any] {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LuxoError(code: statusCode, message: "invalid JSON response", name: "ParseError")
            }
            return json
        } catch {
            throw LuxoError(code: statusCode, message: "invalid JSON response", name: "ParseError")
        }
    }

    private func binaryCall(
        _ api: String,
        params: [String: Any]?,
        headers: [String: String],
        schema: [String: APISchema]
    ) async throws -> Any {
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
            throw LuxoBinaryProtocol.decodeError(data, statusCode: httpResponse.statusCode)
        }

        return data  // Return raw bytes for binary decoding
    }
}

// MARK: - WebSocket Transport

protocol LuxoWebSocketTask: AnyObject, Sendable {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping @Sendable (Error?) -> Void
    )
    func receive(
        completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void
    )
}

extension URLSessionWebSocketTask: LuxoWebSocketTask {}

protocol LuxoWebSocketSession: AnyObject {
    func makeWebSocketTask(with request: URLRequest) -> LuxoWebSocketTask
}

extension URLSession: LuxoWebSocketSession {
    func makeWebSocketTask(with request: URLRequest) -> LuxoWebSocketTask {
        webSocketTask(with: request)
    }
}

/// WebSocket transport for streaming (subscriptions) and bidirectional communication.
/// Supports exponential backoff auto-reconnect on disconnect.
public final class WebSocketTransport: Transport, @unchecked Sendable {
    private struct Subscription {
        let params: [String: Any]
        let handler: (Any) -> Void
    }

    private struct PendingCall {
        let continuation: CheckedContinuation<Any, Error>
        let timeoutTask: DispatchWorkItem
    }

    private struct PendingSubscription {
        let continuation: CheckedContinuation<Void, Error>
        let timeoutTask: DispatchWorkItem
    }

    private let url: URL
    private let session: LuxoWebSocketSession
    private let lock = NSLock()
    private let timeout: TimeInterval
    private var task: LuxoWebSocketTask?
    private var subscriptions: [String: Subscription] = [:]
    private var pending: [UInt64: PendingCall] = [:]
    private var pendingSubscriptions: [String: PendingSubscription] = [:]
    private var schema: [String: APISchema] = [:]
    private var apiByID: [UInt64: String] = [:]
    private var mode: TransportMode = .json
    private var token: String?
    private var sequence: UInt64 = 0

    private var shouldReconnect = true
    private var reconnectAttempt = 0
    private let maxBackoff: TimeInterval
    private let baseBackoff: TimeInterval

    public convenience init(
        url: String,
        token: String? = nil,
        timeout: TimeInterval = 30
    ) throws {
        try self.init(
            url: url,
            token: token,
            timeout: timeout,
            session: URLSession(configuration: .default),
            baseBackoff: 1,
            maxBackoff: 30
        )
    }

    init(
        url: String,
        token: String? = nil,
        timeout: TimeInterval = 30,
        session: LuxoWebSocketSession,
        baseBackoff: TimeInterval = 1,
        maxBackoff: TimeInterval = 30
    ) throws {
        self.url = try validatedURL(url, schemes: ["ws", "wss"])
        guard timeout > 0 else {
            throw LuxoError(code: 0, message: "timeout must be greater than zero", name: "ConfigError")
        }
        guard baseBackoff > 0, maxBackoff >= baseBackoff else {
            throw LuxoError(code: 0, message: "invalid reconnect backoff", name: "ConfigError")
        }
        self.token = token
        self.timeout = timeout
        self.session = session
        self.baseBackoff = baseBackoff
        self.maxBackoff = maxBackoff
    }

    public func setToken(_ token: String) {
        lock.withLock { self.token = token }
    }

    public func setMode(_ mode: TransportMode) {
        lock.withLock { self.mode = mode }
    }

    public func setSchema(_ schema: [String: APISchema]) {
        lock.withLock {
            self.schema = schema
            self.apiByID = Dictionary(uniqueKeysWithValues: schema.map { (UInt64($0.value.id), $0.key) })
        }
    }

    public func connect() {
        let previous = lock.withLock { () -> LuxoWebSocketTask? in
            shouldReconnect = true
            reconnectAttempt = 0
            let current = task
            task = nil
            return current
        }
        previous?.cancel(with: .goingAway, reason: nil)
        openConnection()
    }

    public func call(_ api: String, params: [String: Any]? = nil) async throws -> Any {
        let request = try lock.withLock { () throws -> (UInt64, LuxoWebSocketTask, URLSessionWebSocketTask.Message) in
            guard let socket = task else {
                throw LuxoError(code: 0, message: "WebSocket not connected", name: "ConnectionError")
            }
            sequence &+= 1
            let requestID = sequence
            if mode == .binary {
                guard let apiSchema = schema[api] else {
                    throw LuxoError(
                        code: 0,
                        message: "no schema for API \"\(api)\" — binary mode requires schema",
                        name: "ConfigError"
                    )
                }
                let body = try LuxoBinaryProtocol.encodeRequest(schema: apiSchema, params: params)
                return (requestID, socket, .data(LuxoBinaryProtocol.callFrame(sequence: requestID, body: body)))
            }
            var body = params ?? [:]
            body["$id"] = requestID
            body["$api"] = api
            let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            return (requestID, socket, .string(String(decoding: data, as: UTF8.self)))
        }

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = DispatchWorkItem { [weak self] in
                self?.failPending(
                    request.0,
                    error: LuxoError(
                        code: 0,
                        message: "WebSocket call \"\(api)\" timed out",
                        name: "TimeoutError"
                    ))
            }
            lock.withLock {
                pending[request.0] = PendingCall(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutTask)
            let requestID = request.0
            request.1.send(request.2) { [weak self] error in
                guard let error else { return }
                self?.failPending(
                    requestID,
                    error: LuxoError(
                        code: 0,
                        message: error.localizedDescription,
                        name: "NetworkError"
                    ))
            }
        }
    }

    public func subscribe(
        _ api: String,
        params: [String: Any]? = nil,
        handler: @escaping (Any) -> Void
    ) async throws -> () -> Void {
        let values = params ?? [:]
        let request = try subscriptionMessage(api, params: values)
        try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = DispatchWorkItem { [weak self] in
                self?.failSubscription(
                    api,
                    error: LuxoError(
                        code: 0,
                        message: "WebSocket subscription \"\(api)\" timed out",
                        name: "TimeoutError"
                    ))
            }
            let duplicate = lock.withLock { () -> Bool in
                guard subscriptions[api] == nil else { return true }
                subscriptions[api] = Subscription(params: values, handler: handler)
                pendingSubscriptions[api] = PendingSubscription(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                return false
            }
            if duplicate {
                continuation.resume(
                    throwing: LuxoError(
                        code: 0,
                        message: "already subscribed to \"\(api)\"",
                        name: "ConfigError"
                    ))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutTask)
            request.0.send(request.1) { [weak self] error in
                guard let error else { return }
                self?.failSubscription(
                    api,
                    error: LuxoError(
                        code: 0,
                        message: error.localizedDescription,
                        name: "NetworkError"
                    ))
            }
        }
        return { [weak self] in self?.unsubscribe(api) }
    }

    public func unsubscribe(_ api: String) {
        let result: (LuxoWebSocketTask?, URLSessionWebSocketTask.Message?) = lock.withLock {
            guard subscriptions.removeValue(forKey: api) != nil else { return (nil, nil) }
            pendingSubscriptions.removeValue(forKey: api)?.timeoutTask.cancel()
            if mode == .binary, let apiSchema = schema[api] {
                return (task, .data(LuxoBinaryProtocol.unsubscribeFrame(apiID: apiSchema.id)))
            }
            let data = try? JSONSerialization.data(withJSONObject: ["$unsub": api])
            return (task, data.map { .string(String(decoding: $0, as: UTF8.self)) })
        }
        if let socket = result.0, let message = result.1 { socket.send(message) { _ in } }
    }

    public func close() {
        let state = lock.withLock {
            () -> (
                LuxoWebSocketTask?,
                [PendingCall],
                [PendingSubscription]
            ) in
            shouldReconnect = false
            let socket = task
            task = nil
            subscriptions.removeAll()
            let calls = Array(pending.values)
            let acknowledgements = Array(pendingSubscriptions.values)
            pending.removeAll()
            pendingSubscriptions.removeAll()
            return (socket, calls, acknowledgements)
        }
        state.0?.cancel(with: .normalClosure, reason: nil)
        let error = LuxoError(code: 0, message: "WebSocket closed by client", name: "ConnectionError")
        state.1.forEach {
            $0.timeoutTask.cancel()
            $0.continuation.resume(throwing: error)
        }
        state.2.forEach {
            $0.timeoutTask.cancel()
            $0.continuation.resume(throwing: error)
        }
    }

    private func openConnection() {
        let request: URLRequest = lock.withLock {
            var request = URLRequest(url: url)
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            return request
        }
        let socket = session.makeWebSocketTask(with: request)
        lock.withLock { task = socket }
        socket.resume()
        let currentSubscriptions = lock.withLock { subscriptions }
        for (api, subscription) in currentSubscriptions {
            sendConfirmedSubscription(api, params: subscription.params, socket: socket)
        }
        receiveLoop(socket)
    }

    private func receiveLoop(_ socket: LuxoWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.lock.withLock { self.reconnectAttempt = 0 }
                self.handleMessage(message)
                self.receiveLoop(socket)
            case .failure(let error):
                let current = self.lock.withLock { () -> Bool in
                    guard self.task === socket else { return false }
                    self.task = nil
                    return true
                }
                guard current else { return }
                self.failAllPending(error)
                self.scheduleReconnect()
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            if lock.withLock({ mode }) == .binary {
                handleBinaryMessage(data)
            } else {
                handleJSONData(data)
            }
        case .string(let text):
            handleJSONData(Data(text.utf8))
        @unknown default:
            break
        }
    }

    private func handleJSONData(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let acknowledgement = LuxoWebSocketProtocol.decodeJSONSubscriptionAcknowledgement(json),
            let api = acknowledgement.api
        {
            acknowledgeSubscription(api, error: acknowledgement.error)
            return
        }
        if let api = json["$stream"] as? String {
            let handler = lock.withLock { subscriptions[api]?.handler }
            handler?(json["data"] ?? NSNull())
            return
        }
        guard let number = json["$id"] as? NSNumber else { return }
        let requestID = number.uint64Value
        guard let state = lock.withLock({ pending.removeValue(forKey: requestID) }) else { return }
        state.timeoutTask.cancel()
        if json["error"] != nil {
            state.continuation.resume(throwing: LuxoError.from(json: json))
        } else {
            state.continuation.resume(returning: json["data"] ?? NSNull())
        }
    }

    private func handleBinaryMessage(_ data: Data) {
        if let acknowledgement = LuxoWebSocketProtocol.decodeBinarySubscriptionAcknowledgement(data),
            let apiID = acknowledgement.apiID,
            let api = lock.withLock({ apiByID[apiID] })
        {
            acknowledgeSubscription(api, error: acknowledgement.error)
            return
        }
        var decoder = Decoder(data)
        let frameType = decoder.readVarint()
        let id = decoder.readVarint()
        let payload = decoder.readRemainingData()
        switch frameType {
        case LuxoBinaryProtocol.callSuccess:
            if let state = lock.withLock({ pending.removeValue(forKey: id) }) {
                state.timeoutTask.cancel()
                state.continuation.resume(returning: payload)
            }
        case LuxoBinaryProtocol.callError:
            if let state = lock.withLock({ pending.removeValue(forKey: id) }) {
                state.timeoutTask.cancel()
                state.continuation.resume(
                    throwing: LuxoBinaryProtocol.decodeError(payload, statusCode: 0)
                )
            }
        case LuxoBinaryProtocol.stream:
            let handler = lock.withLock { () -> ((Any) -> Void)? in
                guard let api = apiByID[id] else { return nil }
                return subscriptions[api]?.handler
            }
            handler?(payload)
        default:
            break
        }
    }

    private func subscriptionMessage(
        _ api: String,
        params: [String: Any]
    ) throws -> (LuxoWebSocketTask, URLSessionWebSocketTask.Message) {
        try lock.withLock {
            guard let socket = task else {
                throw LuxoError(code: 0, message: "WebSocket not connected", name: "ConnectionError")
            }
            if mode == .binary {
                guard let apiSchema = schema[api] else {
                    throw LuxoError(code: 0, message: "no schema for API \"\(api)\"", name: "ConfigError")
                }
                let body = try LuxoBinaryProtocol.encodeRequest(schema: apiSchema, params: params)
                return (socket, .data(LuxoBinaryProtocol.subscribeFrame(body: body)))
            }
            var body = params
            body["$sub"] = api
            let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            return (socket, .string(String(decoding: data, as: UTF8.self)))
        }
    }

    private func sendConfirmedSubscription(
        _ api: String,
        params: [String: Any],
        socket: LuxoWebSocketTask
    ) {
        guard let request = try? subscriptionMessage(api, params: params), request.0 === socket else { return }
        socket.send(request.1) { _ in }
    }

    private func failPending(_ id: UInt64, error: Error) {
        guard let state = lock.withLock({ pending.removeValue(forKey: id) }) else { return }
        state.timeoutTask.cancel()
        state.continuation.resume(throwing: error)
    }

    private func failSubscription(_ api: String, error: Error) {
        let state = lock.withLock { () -> PendingSubscription? in
            subscriptions.removeValue(forKey: api)
            return pendingSubscriptions.removeValue(forKey: api)
        }
        guard let state else { return }
        state.timeoutTask.cancel()
        state.continuation.resume(throwing: error)
    }

    private func acknowledgeSubscription(_ api: String, error: LuxoError?) {
        let state = lock.withLock { () -> PendingSubscription? in
            if error != nil { subscriptions.removeValue(forKey: api) }
            return pendingSubscriptions.removeValue(forKey: api)
        }
        state?.timeoutTask.cancel()
        guard let state else { return }
        if let error {
            state.continuation.resume(throwing: error)
        } else {
            state.continuation.resume()
        }
    }

    private func failAllPending(_ underlyingError: Error) {
        let state = lock.withLock { () -> ([PendingCall], [PendingSubscription]) in
            let calls = Array(pending.values)
            let acknowledgements = Array(pendingSubscriptions.values)
            for api in pendingSubscriptions.keys { subscriptions.removeValue(forKey: api) }
            pending.removeAll()
            pendingSubscriptions.removeAll()
            return (calls, acknowledgements)
        }
        let error = LuxoError(
            code: 0,
            message: "WebSocket connection lost: \(underlyingError.localizedDescription)",
            name: "ConnectionError"
        )
        state.0.forEach {
            $0.timeoutTask.cancel()
            $0.continuation.resume(throwing: error)
        }
        state.1.forEach {
            $0.timeoutTask.cancel()
            $0.continuation.resume(throwing: error)
        }
    }

    private func scheduleReconnect() {
        let delay: TimeInterval? = lock.withLock {
            guard shouldReconnect else { return nil }
            let value = min(baseBackoff * pow(2, Double(reconnectAttempt)), maxBackoff)
            reconnectAttempt += 1
            return value
        }
        guard let delay else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.lock.withLock({ self.shouldReconnect }) else { return }
            self.openConnection()
        }
    }
}

private func validatedURL(_ value: String, schemes: Set<String>) throws -> URL {
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
