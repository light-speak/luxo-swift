import Foundation

/// Decodes typed JSON without converting generic numeric tokens.
public struct LuxoJSONDecoder: Sendable {
    public init() {}

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let schema = (type as? any LuxoJSONSchemaProviding.Type)?.luxoJSONSchema
        if let schema { return try JSONTreeDecoder(value: JSONReader.decode(data, schema: schema)).decode(type) }
        if type is any JSONCodableLeaf.Type { return try JSONTreeDecoder(value: JSONReader.decode(data)).decode(type) }
        let value: LuxoValue
        // Every source occurrence is checked, including values later replaced by duplicate keys.
        do { value = try JSONReader.decodeCodable(data) } catch is JSONCodableContextRequired {
            let document = try JSONCodableDocument(data)
            return try JSONCodableDecoder(document: document, range: document.root).decode(type)
        }
        return try JSONTreeDecoder(value: value).decode(type)
    }

    /// Generated outputs call this only after decoding an empty projection.
    /// Other Codable formats do not inherit Luxo's JSON wire constraints.
    public static func validateEmptyModelProjection(from decoder: Swift.Decoder) throws {
        if let decoder = decoder as? JSONCodableDecoder {
            guard let key = decoder.key as? JSONCodingKey, key.intValue != nil else { return }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "model list item has no selected schema field"))
        }
        guard let tree = decoder as? JSONTreeDecoder,
            let key = tree.key as? JSONCodingKey, key.intValue != nil
        else { return }
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: tree.codingPath, debugDescription: "model list item has no selected schema field"))
    }
}

struct JSONTreeDecoder: Swift.Decoder {
    let value: LuxoValue
    var parentPath: [any CodingKey] = []
    var key: (any CodingKey)?
    var codingPath: [any CodingKey] { key.map { parentPath + [$0] } ?? parentPath }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if type == Data.self {
            guard case .string(let text) = value, let bytes = Data(base64Encoded: text), let result = bytes as? T else {
                throw mismatch(type)
            }
            return result
        }
        return try T(from: self)
    }

    func child(_ value: LuxoValue, key: any CodingKey) -> JSONTreeDecoder {
        JSONTreeDecoder(value: value, parentPath: codingPath, key: key)
    }

    func mismatch(_ type: Any.Type) -> DecodingError {
        .typeMismatch(type, .init(codingPath: codingPath, debugDescription: "invalid Luxo JSON value"))
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let values) = value else { throw mismatch([String: LuxoValue].self) }
        return KeyedDecodingContainer(JSONKeyedContainer<Key>(decoder: self, values: values))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard case .array(let values) = value else { throw mismatch([LuxoValue].self) }
        return JSONArrayContainer(decoder: self, values: values)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer { JSONSingleContainer(decoder: self) }
}

private struct JSONSingleContainer: SingleValueDecodingContainer {
    let decoder: JSONTreeDecoder
    var codingPath: [any CodingKey] { decoder.codingPath }

    func decodeNil() -> Bool { if case .null = decoder.value { return true }; return false }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try decoder.decode(type) }
    func decode(_ type: Bool.Type) throws -> Bool { try boolean() }
    func decode(_ type: String.Type) throws -> String { try string() }
    func decode(_ type: Double.Type) throws -> Double { try double() }
    func decode(_ type: Float.Type) throws -> Float { try float() }
    func decode(_ type: Int.Type) throws -> Int { try integer(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try integer(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try integer(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try integer(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try integer(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try integer(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try integer(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try integer(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try integer(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try integer(type) }

    private func boolean() throws -> Bool {
        guard case .bool(let value) = decoder.value else { throw decoder.mismatch(Bool.self) }
        return value
    }

    private func string() throws -> String {
        guard case .string(let value) = decoder.value else { throw decoder.mismatch(String.self) }
        return value
    }

    private func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        switch decoder.value {
        case .int(let value):
            if let result = T(exactly: value) { return result }
        case .jsonNumber(let value):
            if value.isInteger, let result = T(value.literal) { return result }
        default: break
        }
        throw decoder.mismatch(type)
    }

    private func double() throws -> Double {
        switch decoder.value {
        case .int(let value): return Double(value)
        case .float(let value) where value.isFinite: return value
        case .jsonNumber(let value):
            do { return try value.toDouble() } catch { throw decoder.mismatch(Double.self) }
        default: throw decoder.mismatch(Double.self)
        }
    }

    private func float() throws -> Float {
        let source = try double()
        let result = Float(source)
        guard result.isFinite, result != 0 || source == 0 else { throw decoder.mismatch(Float.self) }
        return result
    }
}

private struct JSONKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: JSONTreeDecoder
    let values: [String: LuxoValue]
    var codingPath: [any CodingKey] { decoder.codingPath }
    var allKeys: [Key] { values.keys.compactMap(Key.init(stringValue:)) }

    func contains(_ key: Key) -> Bool { values[key.stringValue] != nil }

    private func child(_ key: Key) throws -> JSONTreeDecoder {
        guard let value = values[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "missing JSON key"))
        }
        return decoder.child(value, key: key)
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        if case .null = try child(key).value { return true }
        return false
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T { try child(key).decode(type) }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        try scalar(type, forKey: key) { try $0.decode(type) }
    }
    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        try scalar(type, forKey: key) { try $0.decode(type) }
    }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        try scalar(type, forKey: key) { try $0.decode(type) }
    }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        try scalar(type, forKey: key) { try $0.decode(type) }
    }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        try scalar(type, forKey: key) { try $0.decode(type) }
    }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        try scalar(type, forKey: key) { try $0.decode(type) }
    }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        try scalar(type, forKey: key) { try $0.decode(type) }
    }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        try scalar(type, forKey: key) { try $0.decode(type) }
    }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        try scalar(type, forKey: key) { try $0.decode(type) }
    }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        try scalar(type, forKey: key) { try $0.decode(type) }
    }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        try scalar(type, forKey: key) { try $0.decode(type) }
    }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        try scalar(type, forKey: key) { try $0.decode(type) }
    }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        try scalar(type, forKey: key) { try $0.decode(type) }
    }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        try scalar(type, forKey: key) { try $0.decode(type) }
    }

    // Avoid constructing a child decoder/coding path for valid primitive fields.
    private func scalar<T>(_ type: T.Type, forKey key: Key, read: (JSONSingleContainer) throws -> T) throws -> T {
        guard let value = values[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "missing JSON key"))
        }
        do { return try read(JSONSingleContainer(decoder: JSONTreeDecoder(value: value))) } catch {
            throw decoder.child(value, key: key).mismatch(type)
        }
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws
        -> KeyedDecodingContainer<NestedKey>
    {
        try child(key).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try child(key).unkeyedContainer()
    }
    func superDecoder(forKey key: Key) throws -> any Swift.Decoder { try child(key) }
    func superDecoder() throws -> any Swift.Decoder {
        let key = JSONCodingKey(stringValue: "super")
        return decoder.child(values[key.stringValue] ?? .null, key: key)
    }
}

private struct JSONArrayContainer: UnkeyedDecodingContainer {
    let decoder: JSONTreeDecoder
    let values: [LuxoValue]
    var currentIndex = 0
    var codingPath: [any CodingKey] { decoder.codingPath }
    var count: Int? { values.count }
    var isAtEnd: Bool { currentIndex == values.count }

    private func child() throws -> JSONTreeDecoder {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(
                LuxoValue.self, .init(codingPath: codingPath, debugDescription: "end of JSON array"))
        }
        return decoder.child(values[currentIndex], key: JSONCodingKey(intValue: currentIndex))
    }

    mutating func decodeNil() throws -> Bool {
        guard case .null = try child().value else { return false }
        currentIndex += 1
        return true
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let result = try child().decode(type)
        currentIndex += 1
        return result
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool { try read { try $0.decode(type) } }
    mutating func decode(_ type: String.Type) throws -> String { try read { try $0.decode(type) } }
    mutating func decode(_ type: Double.Type) throws -> Double { try read { try $0.decode(type) } }
    mutating func decode(_ type: Float.Type) throws -> Float { try read { try $0.decode(type) } }
    mutating func decode(_ type: Int.Type) throws -> Int { try read { try $0.decode(type) } }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try read { try $0.decode(type) } }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try read { try $0.decode(type) } }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try read { try $0.decode(type) } }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try read { try $0.decode(type) } }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try read { try $0.decode(type) } }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try read { try $0.decode(type) } }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try read { try $0.decode(type) } }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try read { try $0.decode(type) } }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try read { try $0.decode(type) } }

    private mutating func read<T>(_ body: (JSONSingleContainer) throws -> T) throws -> T {
        let result = try body(JSONSingleContainer(decoder: child()))
        currentIndex += 1
        return result
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<
        NestedKey
    > {
        let result = try child().container(keyedBy: type)
        currentIndex += 1
        return result
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let result = try child().unkeyedContainer()
        currentIndex += 1
        return result
    }

    mutating func superDecoder() throws -> any Swift.Decoder {
        let result = try child()
        currentIndex += 1
        return result
    }
}

struct JSONCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init(intValue: Int) { self.intValue = intValue; stringValue = String(intValue) }
}
