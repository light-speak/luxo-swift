import Foundation

struct JSONCodableContextRequired: Error {}

extension JSONReader {
    static func decodeCodable(_ data: Data) throws -> LuxoValue {
        try readDocument(data) { try $0.codableValue(depth: 0, objects: 0) }
    }

    private mutating func codableValue(depth: Int, objects: Int) throws -> LuxoValue {
        whitespace()
        if current == 123 || current == 91 {
            guard depth < 128 else { throw JSONCodableContextRequired() }
        }
        if current == 123 {
            guard objects < 64 else { throw JSONCodableContextRequired() }
            return try typedObject(materialize: true) { reader, _ in
                try reader.codableValue(depth: depth + 1, objects: objects + 1)
            }
        }
        if current == 91 {
            return try typedArray(materialize: true) {
                try $0.codableValue(depth: depth + 1, objects: objects)
            }
        }
        return try value(depth: 0)
    }
}

protocol JSONCodableLeaf: Decodable {}
extension Bool: JSONCodableLeaf {}
extension String: JSONCodableLeaf {}
extension Double: JSONCodableLeaf {}
extension Float: JSONCodableLeaf {}
extension Int: JSONCodableLeaf {}
extension Int8: JSONCodableLeaf {}
extension Int16: JSONCodableLeaf {}
extension Int32: JSONCodableLeaf {}
extension Int64: JSONCodableLeaf {}
extension UInt: JSONCodableLeaf {}
extension UInt8: JSONCodableLeaf {}
extension UInt16: JSONCodableLeaf {}
extension UInt32: JSONCodableLeaf {}
extension UInt64: JSONCodableLeaf {}
extension Data: JSONCodableLeaf {}
extension UUID: JSONCodableLeaf {}
extension Date: JSONCodableLeaf {}
extension Optional: JSONCodableLeaf where Wrapped: JSONCodableLeaf {}
extension Array: JSONCodableLeaf where Element: JSONCodableLeaf {}
extension Dictionary: JSONCodableLeaf where Key: JSONCodableLeaf, Value: JSONCodableLeaf {}

/// Structural offsets let Codable choose typed budgets before values are materialized.
final class JSONCodableDocument {
    struct Boundary {
        let start: Int
        var end: Int
        var count: Int
    }
    private struct Frame {
        let boundary: Int
        let closing: UInt8
        var count = 0
    }
    let data: Data
    let boundaries: [Boundary]
    let root: Range<Int>

    init(_ data: Data) throws {
        self.data = data
        let indexed = try JSONReader.readDocument(data) { reader in
            reader.whitespace()
            let start = reader.offset
            let boundaries = try Self.index(&reader)
            let end = reader.offset
            return (boundaries, start..<end)
        }
        boundaries = indexed.0
        root = indexed.1
    }

    private static func index(_ reader: inout JSONReader) throws -> [Boundary] {
        var result: [Boundary] = []
        var frames: [Frame] = []
        // Contextual decoding follows a depth probe; bound capacity before indexing deep inputs.
        let capacity = min(128, reader.bytes.count / 2)
        result.reserveCapacity(capacity)
        frames.reserveCapacity(capacity)
        try startValue(&reader, result: &result, frames: &frames)
        while let frame = frames.last {
            reader.whitespace()
            if reader.take(frame.closing) {
                result[frame.boundary].end = reader.offset
                result[frame.boundary].count = frame.count
                frames.removeLast()
                continue
            }
            if frame.count != 0 {
                guard reader.take(44) else { throw reader.invalid() }
                reader.whitespace()
            }
            if frame.closing == 125 {
                guard reader.current == 34 else { throw reader.invalid() }
                try reader.skipValue(depth: 0)
                reader.whitespace()
                guard reader.take(58) else { throw reader.invalid() }
            } else if frame.count >= 1_000_000 {
                throw reader.invalid()
            }
            frames[frames.count - 1].count += 1
            try startValue(&reader, result: &result, frames: &frames)
        }
        return result
    }

    private static func startValue(
        _ reader: inout JSONReader, result: inout [Boundary], frames: inout [Frame]
    ) throws {
        reader.whitespace()
        guard reader.current == 91 || reader.current == 123 else {
            try reader.skipValue(depth: 0)
            return
        }
        // Separate model, typed-collection and generic-JSON budgets are checked when read.
        guard frames.count < 64 + 128 + 128 else {
            throw LuxoError(
                code: 0, message: "typed JSON nesting exceeds combined decoding bounds", name: "DecodingError")
        }
        let index = result.count
        result.append(Boundary(start: reader.offset, end: 0, count: 0))
        frames.append(Frame(boundary: index, closing: reader.current == 91 ? 93 : 125))
        reader.offset += 1
    }

    @inline(__always)
    func read<Value>(_ range: Range<Int>, _ body: (inout JSONReader) throws -> Value) rethrows -> Value {
        try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var reader = JSONReader(
                bytes: UnsafeBufferPointer(start: bytes.baseAddress, count: range.upperBound),
                offset: range.lowerBound)
            return try body(&reader)
        }
    }

    func kind(_ range: Range<Int>) -> UInt8 { read(range) { $0.current } }

    func boundary(_ start: Int) throws -> Boundary {
        var lower = 0
        var upper = boundaries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if boundaries[middle].start < start { lower = middle + 1 } else { upper = middle }
        }
        // Only validated container starts reach this lookup.
        guard lower < boundaries.count, boundaries[lower].start == start else {
            throw LuxoError(code: 0, message: "missing JSON container boundary", name: "DecodingError")
        }
        return boundaries[lower]
    }

    func valueRange(_ reader: inout JSONReader) throws -> Range<Int> {
        reader.whitespace()
        let start = reader.offset
        if reader.current == 91 || reader.current == 123 {
            reader.offset = try boundary(start).end
        } else {
            try reader.skipValue(depth: 0)
        }
        return start..<reader.offset
    }

    func value(_ range: Range<Int>, schema: LuxoJSONReadSchema? = nil, models: Int = 0) throws -> LuxoValue {
        try read(range) { reader in
            try schema.map { try reader.value(schema: $0, objectDepth: models) } ?? reader.value(depth: 0)
        }
    }

    func validate(_ range: Range<Int>) throws { try read(range) { try $0.skipValue(depth: 0) } }
}

private protocol JSONKeyedDecodingWrapper {}
extension Dictionary: JSONKeyedDecodingWrapper {}
extension Optional: JSONKeyedDecodingWrapper where Wrapped: JSONKeyedDecodingWrapper {}
extension Selected: JSONKeyedDecodingWrapper where Value: JSONKeyedDecodingWrapper {}
extension Page: JSONKeyedDecodingWrapper {}
extension Cursor: JSONKeyedDecodingWrapper {}

private protocol JSONCodableDiscardedValue {
    static func validateDiscarded(from decoder: JSONCodableDecoder) throws
}

extension Array: JSONCodableDiscardedValue where Element: Decodable {
    static func validateDiscarded(from decoder: JSONCodableDecoder) throws {
        try decoder.validateArray { child, _ in try child.validateDiscarded(Element.self) }
    }
}

extension Dictionary: JSONCodableDiscardedValue where Key: Decodable, Value: Decodable {
    static func validateDiscarded(from decoder: JSONCodableDecoder) throws {
        if Key.self == String.self || Key.self == Int.self {
            try decoder.validateDictionary(Value.self)
        } else {
            try decoder.validateArray { child, index in
                if index.isMultiple(of: 2) {
                    try child.validateDiscarded(Key.self)
                } else {
                    try child.validateDiscarded(Value.self)
                }
            }
        }
    }
}

extension Optional: JSONCodableDiscardedValue where Wrapped: Decodable {
    static func validateDiscarded(from decoder: JSONCodableDecoder) throws {
        try decoder.validateDiscarded(Wrapped.self)
    }
}

struct JSONCodableDepth {
    var models = 0
    var collections = 0
    var wrappers = 0
}

final class JSONCodableDecoder: Swift.Decoder {
    struct Field {
        let first: Range<Int>
        var later: [Range<Int>] = []
        var consumed = false
        var last: Range<Int> { later.last ?? first }

        func forEachRange(_ body: (Range<Int>) throws -> Void) rethrows {
            try body(first)
            for range in later { try body(range) }
        }
    }
    private enum Purpose { case normal, projection }
    private struct Observation {
        let wholeValue: Bool
        let validate: (JSONCodableDecoder) throws -> Void
    }
    let document: JSONCodableDocument
    let range: Range<Int>
    let depth: JSONCodableDepth
    let parentPath: [any CodingKey]
    let key: (any CodingKey)?
    var codingPath: [any CodingKey] { key.map { parentPath + [$0] } ?? parentPath }
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    private var keyedWrapper = false
    private var fields: [String: Field]?
    private var arrayBoundary: JSONCodableDocument.Boundary?
    private var arrayReadCount = 0
    private var arrayReadEnd = 0
    private var borrowed: [JSONCodableDecoder] = []
    private var previous: [JSONCodableDecoder] = []
    private var observations: [Observation] = []
    private var purpose = Purpose.normal
    private var observes: Bool {
        get { purpose == .projection }
        set { purpose = newValue ? .projection : .normal }
    }
    private var previousChecked = false
    private var checked = false

    init(
        document: JSONCodableDocument, range: Range<Int>, depth: JSONCodableDepth = .init(),
        parentPath: [any CodingKey] = [], key: (any CodingKey)? = nil
    ) {
        self.document = document
        self.range = range
        self.depth = depth
        self.parentPath = parentPath
        self.key = key
    }

    func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        keyedWrapper = type is any JSONKeyedDecodingWrapper.Type
        if let provider = type as? any LuxoJSONSchemaProviding.Type {
            let schema = provider.luxoJSONSchema
            let value = try document.value(range, schema: schema, models: depth.models)
            let result = try JSONTreeDecoder(value: value, parentPath: parentPath, key: key).decode(type)
            if observes {
                observe(wholeValue: true) { try $0.validateDiscarded(schema: schema) }
            }
            checked = true
            if !previous.isEmpty { try finish() }
            return result
        }
        if type == Data.self {
            let result = try scalar(type)
            if !previous.isEmpty { try finish() }
            return result
        }
        let result = try Value(from: self)
        try finish()
        return result
    }

    func child(_ range: Range<Int>, key: any CodingKey, depth: JSONCodableDepth) -> JSONCodableDecoder {
        JSONCodableDecoder(document: document, range: range, depth: depth, parentPath: codingPath, key: key)
    }

    func validateDiscarded<Value: Decodable>(_ type: Value.Type) throws {
        if !previousChecked {
            for decoder in previous { try decoder.validateDiscarded(type) }
            previousChecked = true
        }
        if document.kind(range) == 110 || type is any JSONCodableLeaf.Type {
            try document.validate(range)
        } else if let provider = type as? any LuxoJSONSchemaProviding.Type {
            _ = try document.value(range, schema: provider.luxoJSONSchema, models: depth.models)
        } else if let container = type as? any JSONCodableDiscardedValue.Type {
            try container.validateDiscarded(from: self)
        } else {
            // An unmaterialized value has no observable model fields. Never run a discarded business initializer.
            try document.validate(range)
        }
        checked = true
    }

    private func validateDiscarded(schema: LuxoJSONReadSchema) throws {
        if !previousChecked {
            for decoder in previous { try decoder.validateDiscarded(schema: schema) }
            previousChecked = true
        }
        _ = try document.value(range, schema: schema, models: depth.models)
        checked = true
    }

    func validateArray(_ validate: (JSONCodableDecoder, Int) throws -> Void) throws {
        guard document.kind(range) == 91 else { try document.validate(range); return }
        _ = try unkeyedContainer()
        let count = try document.boundary(range.lowerBound).count
        var next = depth
        next.collections += 1
        next.wrappers = 0
        try document.read((range.lowerBound + 1)..<(range.upperBound - 1)) { reader in
            for index in 0..<count {
                reader.whitespace()
                if index != 0 { guard reader.take(44) else { throw reader.invalid() } }
                let value = try document.valueRange(&reader)
                try validate(child(value, key: JSONCodingKey(intValue: index), depth: next), index)
            }
        }
    }

    func validateDictionary<Value: Decodable>(_ type: Value.Type) throws {
        guard document.kind(range) == 123 else { try document.validate(range); return }
        keyedWrapper = true
        _ = try container(keyedBy: JSONCodingKey.self)
        var next = depth
        next.collections += 1
        next.wrappers = 0
        // Successful keyed-container construction always initializes the indexed fields.
        guard let fields else { throw limit("missing indexed dictionary fields") }
        for (name, field) in fields {
            try field.forEachRange { range in
                try child(range, key: JSONCodingKey(stringValue: name), depth: next).validateDiscarded(type)
            }
        }
    }

    func delegated<Value: Decodable>(_ type: Value.Type) throws -> Value {
        guard depth.wrappers < 128 else { throw limit("Codable wrapper nesting exceeds 128 levels") }
        var next = depth
        next.wrappers += 1
        let decoder = JSONCodableDecoder(
            document: document, range: range, depth: next, parentPath: parentPath, key: key)
        let result = try decoder.decode(type)
        observe(wholeValue: true) { try $0.validateDelegated(type, depth: next) }
        checked = true
        return result
    }

    private func validateDelegated<Value: Decodable>(_ type: Value.Type, depth: JSONCodableDepth) throws {
        if !previousChecked {
            for decoder in previous { try decoder.validateDelegated(type, depth: depth) }
            previousChecked = true
        }
        let decoder = JSONCodableDecoder(
            document: document, range: range, depth: depth, parentPath: parentPath, key: key)
        try decoder.validateDiscarded(type)
        checked = true
    }

    func scalar<Value: Decodable>(_ type: Value.Type) throws -> Value {
        let value = try document.value(range)
        let result = try JSONTreeDecoder(value: value, parentPath: parentPath, key: key).decode(type)
        observe(wholeValue: true) { try $0.validateDiscarded(type) }
        checked = true
        return result
    }

    func scalar<Value: Decodable>(_ type: Value.Type, range: Range<Int>, key: any CodingKey) throws -> Value {
        let value = try document.value(range)
        do { return try JSONTreeDecoder(value: value).decode(type) } catch {
            throw JSONTreeDecoder(value: value, parentPath: codingPath, key: key).mismatch(type)
        }
    }

    func jsonValue() throws -> JSONValue {
        let value = try JSONValue(document.value(range))
        observe(wholeValue: true) { try $0.validateDiscarded(JSONValue.self) }
        checked = true
        return value
    }

    func isNull() -> Bool {
        if document.kind(range) == 110 { checked = true; return true }
        return false
    }

    private func limit(_ message: String) -> LuxoError {
        LuxoError(code: 0, message: message, name: "DecodingError")
    }

    func mismatch(_ type: Any.Type) -> DecodingError {
        .typeMismatch(type, .init(codingPath: codingPath, debugDescription: "invalid Luxo JSON value"))
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard document.kind(range) == 123 else { throw mismatch([String: LuxoValue].self) }
        var nested = depth
        if keyedWrapper {
            guard depth.collections < 128 else { throw limit("typed collection nesting exceeds 128 levels") }
            nested.collections += 1
        } else {
            guard depth.models < 64 else { throw limit("model nesting exceeds 64 levels") }
            nested.models += 1
        }
        nested.wrappers = 0
        if fields == nil { fields = try readFields() }
        observe { _ = try $0.container(keyedBy: type) }
        return KeyedDecodingContainer(JSONCodableKeyedContainer<Key>(decoder: self, depth: nested))
    }

    private func readFields() throws -> [String: Field] {
        try document.read((range.lowerBound + 1)..<(range.upperBound - 1)) { reader in
            var values: [String: Field] = [:]
            reader.whitespace()
            while reader.offset < reader.bytes.count {
                if !values.isEmpty { guard reader.take(44) else { throw reader.invalid() }; reader.whitespace() }
                let name = try reader.string()
                reader.whitespace()
                guard reader.take(58) else { throw reader.invalid() }
                let value = try document.valueRange(&reader)
                if values[name] != nil { values[name]?.later.append(value) } else { values[name] = Field(first: value) }
                reader.whitespace()
            }
            return values
        }
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard document.kind(range) == 91 else { throw mismatch([LuxoValue].self) }
        guard depth.collections < 128 else { throw limit("typed collection nesting exceeds 128 levels") }
        var next = depth
        next.collections += 1
        next.wrappers = 0
        let boundary = try document.boundary(range.lowerBound)
        arrayBoundary = boundary
        observe { _ = try $0.unkeyedContainer() }
        return JSONCodableArrayContainer(
            decoder: self, depth: next, total: boundary.count, cursor: range.lowerBound + 1)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        JSONCodableSingleContainer(decoder: self)
    }

    func field(_ key: any CodingKey) throws -> Field {
        guard let value = fields?[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "missing JSON key"))
        }
        return value
    }

    func allKeys<Key: CodingKey>(_ type: Key.Type) -> [Key] { fields?.keys.compactMap(Key.init(stringValue:)) ?? [] }
    func contains(_ key: any CodingKey) -> Bool { fields?[key.stringValue] != nil }
    func consumed(_ key: any CodingKey) { fields?[key.stringValue]?.consumed = true }
    func borrow(_ child: JSONCodableDecoder) { borrowed.append(child) }

    func observe(wholeValue: Bool = false, _ action: @escaping (JSONCodableDecoder) throws -> Void) {
        if observes { observations.append(Observation(wholeValue: wholeValue, validate: action)) }
    }

    func validateTypedField<Value: Decodable>(_ type: Value.Type, key: any CodingKey, depth: JSONCodableDepth) throws {
        if observes {
            observe { try $0.validateTypedField(type, key: key, depth: depth) }
        }
        guard contains(key) else { return }
        try field(key).forEachRange { range in try child(range, key: key, depth: depth).validateDiscarded(type) }
        consumed(key)
    }

    func validatePrevious<Value: Decodable>(
        _ type: Value.Type, field: Field, key: any CodingKey, depth: JSONCodableDepth
    ) throws {
        guard !field.later.isEmpty else { return }
        try child(field.first, key: key, depth: depth).validateDiscarded(type)
        for range in field.later.dropLast() { try child(range, key: key, depth: depth).validateDiscarded(type) }
    }

    func observeArrayRead(
        at index: Int, depth: JSONCodableDepth,
        _ action: @escaping (JSONCodableDecoder) throws -> Void
    ) {
        observe { decoder in
            _ = try decoder.unkeyedContainer()
            guard let boundary = decoder.arrayBoundary, index < boundary.count else { return }
            let count = index < decoder.arrayReadCount ? 0 : decoder.arrayReadCount
            let start = count == 0 ? decoder.range.lowerBound + 1 : decoder.arrayReadEnd
            let range = try decoder.document.read(start..<(decoder.range.upperBound - 1)) { reader in
                var result = start..<start
                for position in count...index {
                    reader.whitespace()
                    if position != 0 { guard reader.take(44) else { throw reader.invalid() } }
                    result = try decoder.document.valueRange(&reader)
                }
                return result
            }
            let child = decoder.child(range, key: JSONCodingKey(intValue: index), depth: depth)
            try action(child)
            try child.finish()
            decoder.recordArrayRead(count: index + 1, end: range.upperBound)
        }
    }

    func borrowArray(_ child: JSONCodableDecoder, at index: Int, depth: JSONCodableDepth) {
        child.observes = observes
        observeArrayRead(at: index, depth: depth) { try child.project(onto: $0) }
        borrow(child)
    }

    private func project(onto decoder: JSONCodableDecoder) throws {
        guard document.kind(range) == decoder.document.kind(decoder.range) else {
            var typed = false
            for observation in observations where observation.wholeValue {
                try observation.validate(decoder)
                typed = true
            }
            if typed { return }
            try decoder.document.validate(decoder.range)
            decoder.checked = true
            return
        }
        decoder.keyedWrapper = keyedWrapper
        for action in observations { try action.validate(decoder) }
        try decoder.finish()
    }

    func fieldDecoder(_ key: any CodingKey, depth: JSONCodableDepth) throws -> JSONCodableDecoder {
        let field = try field(key)
        let child = child(field.last, key: key, depth: depth)
        child.observes = observes || !field.later.isEmpty
        if !field.later.isEmpty {
            child.previous = ([field.first] + field.later.dropLast()).map {
                self.child($0, key: key, depth: depth)
            }
        }
        return child
    }

    func observeField(_ child: JSONCodableDecoder, key: any CodingKey, depth: JSONCodableDepth) {
        observe { earlier in
            guard earlier.contains(key) else { return }
            try child.project(onto: earlier.fieldDecoder(key, depth: depth))
            earlier.consumed(key)
        }
    }

    func validateField(_ key: any CodingKey) throws {
        guard contains(key) else { return }
        let field = try field(key)
        try field.forEachRange(document.validate)
        consumed(key)
    }

    func nested(_ key: any CodingKey, depth: JSONCodableDepth) throws -> JSONCodableDecoder {
        let child = try fieldDecoder(key, depth: depth)
        observeField(child, key: key, depth: depth)
        borrow(child)
        consumed(key)
        return child
    }

    func recordArrayRead(count: Int, end: Int) {
        if count > arrayReadCount { arrayReadCount = count; arrayReadEnd = end }
    }

    func finish() throws {
        if !previousChecked {
            for decoder in previous { try project(onto: decoder) }
            previousChecked = true
        }
        if checked { return }
        if fields == nil, arrayBoundary == nil, document.kind(range) == 123 {
            _ = try container(keyedBy: JSONCodingKey.self)
        }
        for child in borrowed { try child.finish() }
        if let fields {
            for field in fields.values where !field.consumed {
                try field.forEachRange(document.validate)
            }
        } else if let arrayBoundary {
            try finishArray(arrayBoundary)
        } else {
            try document.validate(range)
        }
        checked = true
    }

    private func finishArray(_ boundary: JSONCodableDocument.Boundary) throws {
        guard arrayReadCount < boundary.count else { return }
        let start = arrayReadCount == 0 ? range.lowerBound + 1 : arrayReadEnd
        try document.read(start..<(range.upperBound - 1)) { reader in
            for index in arrayReadCount..<boundary.count {
                reader.whitespace()
                if index != 0 { guard reader.take(44) else { throw reader.invalid() }; reader.whitespace() }
                try reader.skipValue(depth: 0)
            }
        }
    }
}

private struct JSONCodableSingleContainer: SingleValueDecodingContainer {
    let decoder: JSONCodableDecoder
    var codingPath: [any CodingKey] { decoder.codingPath }
    func decodeNil() -> Bool { decoder.isNull() }
    func decode<Value: Decodable>(_ type: Value.Type) throws -> Value { try decoder.delegated(type) }
    func decode(_ type: Bool.Type) throws -> Bool { try decoder.scalar(type) }
    func decode(_ type: String.Type) throws -> String { try decoder.scalar(type) }
    func decode(_ type: Double.Type) throws -> Double { try decoder.scalar(type) }
    func decode(_ type: Float.Type) throws -> Float { try decoder.scalar(type) }
    func decode(_ type: Int.Type) throws -> Int { try decoder.scalar(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try decoder.scalar(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try decoder.scalar(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try decoder.scalar(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try decoder.scalar(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try decoder.scalar(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try decoder.scalar(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try decoder.scalar(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try decoder.scalar(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try decoder.scalar(type) }
}

private struct JSONCodableKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: JSONCodableDecoder
    let depth: JSONCodableDepth
    var codingPath: [any CodingKey] { decoder.codingPath }
    var allKeys: [Key] { decoder.allKeys(Key.self) }
    func contains(_ key: Key) -> Bool { decoder.contains(key) }

    func decode<Value: Decodable>(_ type: Value.Type, forKey key: Key) throws -> Value {
        if type is any JSONCodableDiscardedValue.Type { return try collection(type, forKey: key) }
        let child = try decoder.fieldDecoder(key, depth: depth)
        let value = try child.decode(type)
        decoder.consumed(key)
        decoder.observeField(child, key: key, depth: depth)
        return value
    }

    private func collection<Value: Decodable>(_ type: Value.Type, forKey key: Key) throws -> Value {
        let field = try decoder.field(key)
        let value = try decoder.child(field.last, key: key, depth: depth).decode(type)
        try decoder.validatePrevious(type, field: field, key: key, depth: depth)
        decoder.consumed(key)
        decoder.observe { earlier in
            try earlier.validateTypedField(type, key: key, depth: depth)
        }
        return value
    }

    private func optional<Value: Decodable>(_ type: Value.Type, forKey key: Key) throws -> Value? {
        guard contains(key) else {
            decoder.observe { try $0.validateTypedField(type, key: key, depth: depth) }
            return nil
        }
        let field = try decoder.field(key)
        func read(_ range: Range<Int>) throws -> Value? {
            let child = decoder.child(range, key: key, depth: depth)
            return child.isNull() ? nil : try child.decode(type)
        }
        let value = try read(field.last)
        try decoder.validatePrevious(type, field: field, key: key, depth: depth)
        decoder.consumed(key)
        decoder.observe { try $0.validateTypedField(type, key: key, depth: depth) }
        return value
    }

    func decodeIfPresent<Value: Decodable>(_ type: Value.Type, forKey key: Key) throws -> Value? {
        try optional(type, forKey: key)
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        let field = try decoder.field(key)
        return decoder.document.kind(field.last) == 110
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try decodeScalar(type, forKey: key) }
    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? { try optional(type, forKey: key) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try decodeScalar(type, forKey: key) }
    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? { try optional(type, forKey: key) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try decodeScalar(type, forKey: key) }
    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? { try optional(type, forKey: key) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try decodeScalar(type, forKey: key) }
    func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? { try optional(type, forKey: key) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try decodeScalar(type, forKey: key) }
    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? { try optional(type, forKey: key) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try decodeScalar(type, forKey: key) }
    func decodeIfPresent(_ type: Int8.Type, forKey key: Key) throws -> Int8? { try optional(type, forKey: key) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try decodeScalar(type, forKey: key) }
    func decodeIfPresent(_ type: Int16.Type, forKey key: Key) throws -> Int16? { try optional(type, forKey: key) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try decodeScalar(type, forKey: key) }
    func decodeIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? { try optional(type, forKey: key) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try decodeScalar(type, forKey: key) }
    func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? { try optional(type, forKey: key) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try decodeScalar(type, forKey: key) }
    func decodeIfPresent(_ type: UInt.Type, forKey key: Key) throws -> UInt? { try optional(type, forKey: key) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try decodeScalar(type, forKey: key) }
    func decodeIfPresent(_ type: UInt8.Type, forKey key: Key) throws -> UInt8? { try optional(type, forKey: key) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try decodeScalar(type, forKey: key) }
    func decodeIfPresent(_ type: UInt16.Type, forKey key: Key) throws -> UInt16? { try optional(type, forKey: key) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try decodeScalar(type, forKey: key) }
    func decodeIfPresent(_ type: UInt32.Type, forKey key: Key) throws -> UInt32? { try optional(type, forKey: key) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try decodeScalar(type, forKey: key) }
    func decodeIfPresent(_ type: UInt64.Type, forKey key: Key) throws -> UInt64? { try optional(type, forKey: key) }
    private func decodeScalar<Value: Decodable>(_ type: Value.Type, forKey key: Key) throws -> Value {
        let field = try decoder.field(key)
        if !field.later.isEmpty {
            try decoder.document.validate(field.first)
            for range in field.later.dropLast() { try decoder.document.validate(range) }
        }
        let result = try decoder.scalar(type, range: field.last, key: key)
        decoder.consumed(key)
        decoder.observe { try $0.validateField(key) }
        return result
    }

    private func nested(_ key: any CodingKey) throws -> JSONCodableDecoder {
        try decoder.nested(key, depth: depth)
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws
        -> KeyedDecodingContainer<NestedKey>
    {
        try nested(key).container(keyedBy: type)
    }
    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try nested(key).unkeyedContainer()
    }
    func superDecoder(forKey key: Key) throws -> any Swift.Decoder { try nested(key) }
    func superDecoder() throws -> any Swift.Decoder {
        let key = JSONCodingKey(stringValue: "super")
        guard decoder.contains(key) else {
            return JSONTreeDecoder(value: .null, parentPath: codingPath, key: JSONCodingKey(stringValue: "super"))
        }
        return try nested(key)
    }
}

private struct JSONCodableArrayContainer: UnkeyedDecodingContainer {
    let decoder: JSONCodableDecoder
    let depth: JSONCodableDepth
    let total: Int
    var cursor: Int
    var currentIndex = 0
    var codingPath: [any CodingKey] { decoder.codingPath }
    var count: Int? { total }
    var isAtEnd: Bool { currentIndex == total }

    private func child() throws -> JSONCodableDecoder {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(
                LuxoValue.self, .init(codingPath: codingPath, debugDescription: "end of JSON array"))
        }
        let range = try decoder.document.read(cursor..<(decoder.range.upperBound - 1)) { reader in
            reader.whitespace()
            if currentIndex != 0 { guard reader.take(44) else { throw reader.invalid() } }
            return try decoder.document.valueRange(&reader)
        }
        return decoder.child(range, key: JSONCodingKey(intValue: currentIndex), depth: depth)
    }

    private mutating func advance(_ child: JSONCodableDecoder) {
        currentIndex += 1
        cursor = child.range.upperBound
        decoder.recordArrayRead(count: currentIndex, end: cursor)
    }

    mutating func decodeNil() throws -> Bool {
        let child = try child()
        guard child.isNull() else { return false }
        decoder.observeArrayRead(at: currentIndex, depth: depth) { _ = $0.isNull() }
        advance(child)
        return true
    }

    mutating func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        let child = try child()
        let value = try child.decode(type)
        decoder.observeArrayRead(at: currentIndex, depth: depth) { try $0.validateDiscarded(type) }
        advance(child)
        return value
    }
    mutating func decode(_ type: Bool.Type) throws -> Bool { try readScalar(type) }
    mutating func decode(_ type: String.Type) throws -> String { try readScalar(type) }
    mutating func decode(_ type: Double.Type) throws -> Double { try readScalar(type) }
    mutating func decode(_ type: Float.Type) throws -> Float { try readScalar(type) }
    mutating func decode(_ type: Int.Type) throws -> Int { try readScalar(type) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try readScalar(type) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try readScalar(type) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try readScalar(type) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try readScalar(type) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try readScalar(type) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try readScalar(type) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try readScalar(type) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try readScalar(type) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try readScalar(type) }
    private mutating func readScalar<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try decode(type)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<
        NestedKey
    > {
        let child = try child()
        decoder.borrowArray(child, at: currentIndex, depth: depth)
        let result = try child.container(keyedBy: type)
        advance(child)
        return result
    }
    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let child = try child()
        decoder.borrowArray(child, at: currentIndex, depth: depth)
        let result = try child.unkeyedContainer()
        advance(child)
        return result
    }
    mutating func superDecoder() throws -> any Swift.Decoder {
        let child = try child()
        decoder.borrowArray(child, at: currentIndex, depth: depth)
        advance(child)
        return child
    }
}
