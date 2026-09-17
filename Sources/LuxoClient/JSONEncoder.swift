import Foundation

/// Encodes Codable values through a typed tree, without a serialize/parse round trip.
public struct LuxoJSONEncoder: Sendable {
    public init() {}
    public func encode<T: Encodable>(_ value: T) throws -> Data { try JSONTreeEncoder.project(value).jsonData() }
}

final class JSONEncodingNode {
    enum Storage {
        case value(LuxoValue), object, array
    }
    var storage: Storage = .value(.null)
    private var fields: [String: JSONEncodingNode] = [:]
    private var elements: [JSONEncodingNode] = []
    var count: Int { elements.count }

    func value(depth: Int = 0) throws -> LuxoValue {
        guard depth <= 128 else { throw JSONTreeEncoder.depthError() }
        switch storage {
        case .value(let value): return value
        case .object: return .object(try fields.mapValues { try $0.value(depth: depth + 1) })
        case .array: return .array(try elements.map { try $0.value(depth: depth + 1) })
        }
    }

    func field(_ key: String) -> JSONEncodingNode {
        let child = JSONEncodingNode()
        fields[key] = child
        return child
    }

    func append() -> JSONEncodingNode {
        let child = JSONEncodingNode()
        elements.append(child)
        return child
    }
}

struct JSONTreeEncoder: Swift.Encoder {
    let node: JSONEncodingNode
    var codingPath: [any CodingKey] = []
    var depth = 0
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    static func project<T: Encodable>(_ value: T) throws -> LuxoValue {
        let encoder = JSONTreeEncoder(node: JSONEncodingNode())
        try encoder.encode(value)
        return try encoder.node.value()
    }

    static func depthError() -> LuxoError {
        LuxoError(code: 0, message: "JSON nesting exceeds 128 levels", name: "EncodingError")
    }

    func checkDepth() throws { if depth > 128 { throw Self.depthError() } }

    func child(_ node: JSONEncodingNode, key: any CodingKey) -> JSONTreeEncoder {
        JSONTreeEncoder(node: node, codingPath: codingPath + [key], depth: depth + 1)
    }

    func encode<T: Encodable>(_ value: T) throws {
        try checkDepth()
        if let value = value as? JSONValue { node.storage = .value(LuxoValue(value)); return }
        if let value = value as? Data { node.storage = .value(.bytes(value)); return }
        try value.encode(to: self)
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        if case .value(.null) = node.storage { node.storage = .object }
        return KeyedEncodingContainer(JSONKeyedEncodingContainer<Key>(encoder: self))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        if case .value(.null) = node.storage { node.storage = .array }
        return JSONArrayEncodingContainer(encoder: self)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer { JSONSingleEncodingContainer(encoder: self) }
}

private struct JSONSingleEncodingContainer: SingleValueEncodingContainer {
    let encoder: JSONTreeEncoder
    var codingPath: [any CodingKey] { encoder.codingPath }

    mutating func encodeNil() throws { try encoder.checkDepth(); encoder.node.storage = .value(.null) }
    mutating func encode<T: Encodable>(_ value: T) throws {
        let nested = JSONTreeEncoder(node: encoder.node, codingPath: codingPath, depth: encoder.depth + 1)
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
