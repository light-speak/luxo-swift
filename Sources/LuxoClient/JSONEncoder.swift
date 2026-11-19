import Foundation

/// Encodes Codable values through a typed tree, without a serialize/parse round trip.
public struct LuxoJSONEncoder: Sendable {
    public init() {}
    public func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONTreeEncoder(node: JSONEncodingNode())
        try encoder.encode(value)
        var writer = JSONWriter()
        try encoder.node.write(to: &writer)
        return Data(writer.bytes)
    }
}

final class JSONEncodingNode {
    enum Storage {
        case value(LuxoValue), dictionary(UInt8), modelObject(UInt8), array(UInt8)
    }
    var storage: Storage = .value(.null)
    private var fields: [String: JSONEncodingNode] = [:]
    private var elements: [JSONEncodingNode] = []
    var count: Int { elements.count }

    var modelDepth: UInt8 { if case .modelObject(let count) = storage { count } else { 0 } }
    var exceedsDepth: Bool {
        switch storage {
        case .modelObject(let count): count > 64
        case .dictionary(let count), .array(let count): count > 128
        case .value: false
        }
    }

    @inline(__always)
    func checkDepth() throws {
        guard exceedsDepth else { return }
        if modelDepth > 64 { throw JSONTreeEncoder.modelDepthError() }
        throw JSONTreeEncoder.depthError()
    }

    func value() throws -> LuxoValue {
        try checkDepth()
        switch storage {
        case .value(let value): return value
        case .dictionary, .modelObject: return .object(try fields.mapValues { try $0.value() })
        case .array: return .array(try elements.map { try $0.value() })
        }
    }

    func write(to writer: inout JSONWriter) throws {
        try checkDepth()
        switch storage {
        case .value(let value): try writer.value(value, depth: 0)
        case .dictionary, .modelObject:
            try writer.object(fields, depth: 0) { writer, _, child in try child.write(to: &writer) }
        case .array:
            try writer.array(elements, depth: 0) { writer, _, child in try child.write(to: &writer) }
        }
    }

    func field(_ key: String) -> JSONEncodingNode {
        if exceedsDepth { return self }
        let child = JSONEncodingNode()
        fields[key] = child
        return child
    }

    func append() -> JSONEncodingNode {
        if exceedsDepth { return self }
        let child = JSONEncodingNode()
        elements.append(child)
        return child
    }
}

struct JSONEncodingDepth {
    var models: UInt8 = 0
    var collections: UInt8 = 0
    var wrappers: UInt8 = 0
}

private protocol JSONKeyedEncodingWrapper {}
extension Dictionary: JSONKeyedEncodingWrapper {}
extension Optional: JSONKeyedEncodingWrapper where Wrapped: JSONKeyedEncodingWrapper {}
extension Selected: JSONKeyedEncodingWrapper where Value: JSONKeyedEncodingWrapper {}
extension Page: JSONKeyedEncodingWrapper {}
extension Cursor: JSONKeyedEncodingWrapper {}

struct JSONTreeEncoder: Swift.Encoder {
    let node: JSONEncodingNode
    var codingPath: [any CodingKey] = []
    var depth = JSONEncodingDepth()
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    static func project<T: Encodable>(_ value: T) throws -> LuxoValue {
        let encoder = JSONTreeEncoder(node: JSONEncodingNode())
        try encoder.encode(value)
        return try encoder.node.value()
    }

    static func depthError() -> LuxoError {
        LuxoError(code: 0, message: "JSON nesting exceeds 128 levels", name: "EncodingError")
    }

    static func modelDepthError() -> LuxoError {
        LuxoError(code: 0, message: "model nesting exceeds 64 levels", name: "EncodingError")
    }

    func checkDepth() throws {
        if depth.models > 64 { throw Self.modelDepthError() }
        if depth.collections > 128 || depth.wrappers > 128 { throw Self.depthError() }
        try node.checkDepth()
    }

    func child(_ node: JSONEncodingNode, key: any CodingKey) -> JSONTreeEncoder {
        JSONTreeEncoder(node: node, codingPath: node.exceedsDepth ? codingPath : codingPath + [key], depth: depth)
    }

    func encode<T: Encodable>(_ value: T) throws {
        try checkDepth()
        if let value = value as? JSONValue { node.storage = .value(try LuxoValue.checkedJSON(value)); return }
        if let value = value as? Data { node.storage = .value(.bytes(value)); return }
        if T.self is any JSONKeyedEncodingWrapper.Type, case .value(.null) = node.storage {
            node.storage = .dictionary(0)
        }
        try value.encode(to: self)
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        var encoder = self
        if case .value(.null) = node.storage {
            node.storage = .modelObject(min(depth.models + 1, 65))
        }
        if case .modelObject(let count) = node.storage { encoder.depth.models = count }
        if case .dictionary(let count) = node.storage {
            let current = count == 0 ? min(depth.collections + 1, 129) : count
            node.storage = .dictionary(current)
            encoder.depth.collections = current
        }
        encoder.depth.wrappers = 0
        return KeyedEncodingContainer(JSONKeyedEncodingContainer<Key>(encoder: encoder))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        var encoder = self
        switch node.storage {
        case .value(.null), .dictionary(0): node.storage = .array(min(depth.collections + 1, 129))
        default: break
        }
        if case .array(let count) = node.storage { encoder.depth.collections = count }
        encoder.depth.wrappers = 0
        return JSONArrayEncodingContainer(encoder: encoder)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer { JSONSingleEncodingContainer(encoder: self) }
}

private struct JSONSingleEncodingContainer: SingleValueEncodingContainer {
    let encoder: JSONTreeEncoder
    var codingPath: [any CodingKey] { encoder.codingPath }

    mutating func encodeNil() throws { try encoder.checkDepth(); encoder.node.storage = .value(.null) }
    mutating func encode<T: Encodable>(_ value: T) throws {
        var nested = encoder
        nested.depth.wrappers = min(encoder.depth.wrappers + 1, 129)
        try nested.encode(value)
    }
    mutating func encode(_ value: Bool) throws { try encoder.checkDepth(); encoder.node.storage = .value(.bool(value)) }
    mutating func encode(_ value: String) throws {
        try encoder.checkDepth(); encoder.node.storage = .value(.string(value))
    }
    mutating func encode(_ value: Double) throws {
        try encoder.checkDepth(); encoder.node.storage = .value(try LuxoValue(finiteFloat: value))
    }
    mutating func encode(_ value: Float) throws {
        try encoder.checkDepth(); encoder.node.storage = .value(try LuxoValue(finiteFloat: Double(value)))
    }
    mutating func encode(_ value: Int) throws {
        try encoder.checkDepth(); encoder.node.storage = .value(.int(Int64(value)))
    }
    mutating func encode(_ value: Int8) throws {
        try encoder.checkDepth(); encoder.node.storage = .value(.int(Int64(value)))
    }
    mutating func encode(_ value: Int16) throws {
        try encoder.checkDepth(); encoder.node.storage = .value(.int(Int64(value)))
    }
    mutating func encode(_ value: Int32) throws {
        try encoder.checkDepth(); encoder.node.storage = .value(.int(Int64(value)))
    }
    mutating func encode(_ value: Int64) throws {
        try encoder.checkDepth(); encoder.node.storage = .value(.int(Int64(value)))
    }
    mutating func encode(_ value: UInt) throws {
        try encoder.checkDepth(); encoder.node.storage = .value(unsigned(UInt64(value)))
    }
    mutating func encode(_ value: UInt8) throws {
        try encoder.checkDepth(); encoder.node.storage = .value(unsigned(UInt64(value)))
    }
    mutating func encode(_ value: UInt16) throws {
        try encoder.checkDepth(); encoder.node.storage = .value(unsigned(UInt64(value)))
    }
    mutating func encode(_ value: UInt32) throws {
        try encoder.checkDepth(); encoder.node.storage = .value(unsigned(UInt64(value)))
    }
    mutating func encode(_ value: UInt64) throws {
        try encoder.checkDepth(); encoder.node.storage = .value(unsigned(UInt64(value)))
    }

    private func unsigned(_ value: UInt64) -> LuxoValue {
        if let signed = Int64(exactly: value) { return .int(signed) }
        return .jsonNumber(JSONNumber(validated: String(value)))
    }
}

private struct JSONKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: JSONTreeEncoder
    var codingPath: [any CodingKey] { encoder.codingPath }

    mutating func encodeNil(forKey key: Key) throws {
        try encoder.checkDepth(); encoder.node.field(key.stringValue).storage = .value(.null)
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        try encoder.child(encoder.node.field(key.stringValue), key: key).encode(value)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key)
        -> KeyedEncodingContainer<NestedKey>
    {
        encoder.child(encoder.node.field(key.stringValue), key: key).container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        encoder.child(encoder.node.field(key.stringValue), key: key).unkeyedContainer()
    }

    mutating func superEncoder(forKey key: Key) -> any Swift.Encoder {
        encoder.child(encoder.node.field(key.stringValue), key: key)
    }

    mutating func superEncoder() -> any Swift.Encoder {
        let key = JSONCodingKey(stringValue: "super")
        return encoder.child(encoder.node.field(key.stringValue), key: key)
    }
}

private struct JSONArrayEncodingContainer: UnkeyedEncodingContainer {
    let encoder: JSONTreeEncoder
    var codingPath: [any CodingKey] { encoder.codingPath }
    var count: Int { encoder.node.count }

    private func next() -> JSONTreeEncoder {
        let key = JSONCodingKey(intValue: count)
        return encoder.child(encoder.node.append(), key: key)
    }

    mutating func encodeNil() throws { var container = next().singleValueContainer(); try container.encodeNil() }
    mutating func encode<T: Encodable>(_ value: T) throws { try next().encode(value) }
    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) -> KeyedEncodingContainer<
        NestedKey
    > {
        next().container(keyedBy: type)
    }
    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer { next().unkeyedContainer() }
    mutating func superEncoder() -> any Swift.Encoder { next() }
}
