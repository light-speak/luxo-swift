import Foundation

private enum CodecLimits {
    static let maxArrayElements: UInt64 = 1_000_000
    static let maxColumnarRecords: UInt64 = 10_000_000
    static let maxArenaSize: UInt64 = 64 * 1024 * 1024
}

// MARK: - Encoder

/// Binary encoder for Luxo protocol. Zero-copy, varint-based.
public struct Encoder {
    public private(set) var data = Data()

    public init() {}

    public mutating func writeVarint(_ value: UInt64) {
        var v = value
        while v > 0x7F {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    public mutating func writeSvarint(_ value: Int64) {
        // ZigZag encoding: (n << 1) ^ (n >> 63)
        let encoded = UInt64(bitPattern: (value << 1) ^ (value >> 63))
        writeVarint(encoded)
    }

    public mutating func writeFixed64(_ value: Double) {
        var v = value.bitPattern
        data.append(contentsOf: withUnsafeBytes(of: &v) { Array($0) })
    }

    public mutating func writeBool(_ value: Bool) {
        data.append(value ? 1 : 0)
    }

    public mutating func writeString(_ value: String) {
        let bytes = Array(value.utf8)
        writeVarint(UInt64(bytes.count))
        data.append(contentsOf: bytes)
    }

    public mutating func writeBytes(_ value: Data) {
        writeVarint(UInt64(value.count))
        writeRawBytes(value)
    }

    public mutating func writeRawBytes(_ value: Data) {
        data.append(value)
    }

    /// Write a fixed 16-byte UUID without a length prefix.
    public mutating func writeUUID(_ value: UUID) {
        let u = value.uuid
        data.append(contentsOf: [
            u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
            u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15,
        ])
    }

    public mutating func writeEnd() {
        data.append(0x00)
    }

    /// Write the array header (varint element count).
    public mutating func writeArrayHeader(_ count: Int) {
        writeVarint(UInt64(count))
    }

    public mutating func writeField(_ fieldID: Int, value: Any, type: String) throws {
        var encoded = Encoder()
        try encoded.writeValue(value, type: type)
        writeVarint(UInt64(fieldID))
        writeRawBytes(encoded.data)
    }

    /// Write a list param field: [fieldID][varint count][item0][item1]...
    /// Each item is encoded by its element type (no per-item field ID).
    public mutating func writeFieldList(_ fieldID: Int, values: [Any], type: String) throws {
        var encoded = Encoder()
        encoded.writeArrayHeader(values.count)
        for value in values {
            try encoded.writeValue(value, type: type)
        }
        writeVarint(UInt64(fieldID))
        writeRawBytes(encoded.data)
    }

    private mutating func writeValue(_ value: Any, type: String) throws {
        switch type {
        case "Int", "Duration":
            if let value = value as? Int64 {
                writeSvarint(value)
            } else if let value = value as? Int {
                writeSvarint(Int64(value))
            } else {
                throw invalidValue(type)
            }
        case "Float":
            if let value = value as? Double {
                writeFixed64(value)
            } else if let value = value as? Float {
                writeFixed64(Double(value))
            } else {
                throw invalidValue(type)
            }
        case "Boolean":
            guard let value = value as? Bool else { throw invalidValue(type) }
            writeBool(value)
        case "UUID":
            if let value = value as? UUID {
                writeUUID(value)
            } else if let value = value as? String, let uuid = UUID(uuidString: value) {
                writeUUID(uuid)
            } else {
                throw invalidValue(type)
            }
        case "String", "Enum", "Decimal":
            guard let value = value as? String else { throw invalidValue(type) }
            writeString(value)
        case "DateTime":
            if let value = value as? Date {
                writeSvarint(Int64(value.timeIntervalSince1970))
            } else if let value = value as? String,
                let date = ISO8601DateFormatter().date(from: value)
            {
                writeSvarint(Int64(date.timeIntervalSince1970))
            } else if let value = value as? Int64 {
                writeSvarint(value)
            } else {
                throw invalidValue(type)
            }
        case "Bytes":
            guard let value = value as? Data else { throw invalidValue(type) }
            writeBytes(value)
        case "JSON":
            if let value = value as? JSONValue {
                writeBytes(try JSONEncoder().encode(value))
            } else {
                guard
                    JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber
                        || value is NSNull
                else {
                    throw invalidValue(type)
                }
                let encoded = try JSONSerialization.data(
                    withJSONObject: value,
                    options: [.fragmentsAllowed, .sortedKeys]
                )
                writeBytes(encoded)
            }
        default:
            throw LuxoError(code: 0, message: "unsupported binary type: \(type)", name: "ConfigError")
        }
    }

    private func invalidValue(_ type: String) -> LuxoError {
        LuxoError(code: 0, message: "invalid \(type) value", name: "ConfigError")
    }
}

// MARK: - Decoder

/// Binary decoder for Luxo protocol.
public struct Decoder {
    private let data: Data
    private var offset: Int = 0

    /// The first wire-format error encountered while decoding.
    public private(set) var error: String?

    public init(_ data: Data) {
        self.data = data
    }

    public var isAtEnd: Bool { offset >= data.count }
    public var remaining: Int { data.count - offset }

    public mutating func readRemainingData() -> Data {
        let remaining = Data(data[offset...])
        offset = data.count
        return remaining
    }

    public mutating func readVarint() -> UInt64 {
        let start = offset
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count {
            let byte = data[offset]
            offset += 1
            if shift >= 64 || (shift == 63 && byte & 0x7E != 0) {
                if error == nil { error = "varint overflow at offset \(start)" }
                return 0
            }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        if error == nil { error = "truncated varint at offset \(start)" }
        return 0
    }

    public mutating func readSvarint() -> Int64 {
        let n = readVarint()
        // ZigZag decode: (n >> 1) ^ -(n & 1)
        return Int64(bitPattern: (n >> 1) ^ (UInt64(bitPattern: -Int64(n & 1))))
    }

    public mutating func readFixed64() -> Double {
        guard offset + 8 <= data.count else {
            if error == nil { error = "truncated fixed64 at offset \(offset)" }
            return 0
        }
        let bits = data[offset..<offset + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        offset += 8
        return Double(bitPattern: bits)
    }

    public mutating func readBool() -> Bool {
        return readCanonicalMarker("bool")
    }

    public mutating func readString() -> String {
        let rawLength = readVarint()
        guard error == nil, rawLength <= UInt64(Int.max) else { return "" }
        let len = Int(rawLength)
        guard len <= data.count - offset else {
            if error == nil { error = "truncated string at offset \(offset)" }
            return ""
        }
        guard let str = String(data: data[offset..<offset + len], encoding: .utf8) else {
            if error == nil { error = "invalid UTF-8 string at offset \(offset)" }
            return ""
        }
        offset += len
        return str
    }

    public mutating func readBytes() -> Data {
        let rawLength = readVarint()
        guard error == nil, rawLength <= UInt64(Int.max) else { return Data() }
        let len = Int(rawLength)
        guard len <= data.count - offset else {
            if error == nil { error = "truncated bytes at offset \(offset)" }
            return Data()
        }
        let bytes = data[offset..<offset + len]
        offset += len
        return Data(bytes)
    }

    /// Read a fixed 16-byte UUID (no length prefix). Returns a zero UUID on truncation.
    public mutating func readUUID() -> UUID {
        guard offset + 16 <= data.count else {
            if error == nil { error = "truncated uuid at offset \(offset)" }
            return UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        }
        let b = data[offset..<offset + 16]
        offset += 16
        let a = Array(b)
        return UUID(
            uuid: (
                a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7],
                a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15]
            ))
    }

    /// Read a nullable UUID (null flag + 16 bytes).
    public mutating func readUUIDPtr() -> UUID? {
        if !readNullFlag() { return nil }
        return readUUID()
    }

    // MARK: - DateTime

    /// Read a DateTime field: svarint(unix seconds) → RFC3339/ISO-8601 UTC `String`.
    ///
    /// Go's wire format (`FieldDateTime`) is an int64 unix timestamp; in JSON mode Go
    /// emits the same instant as an RFC3339 string. Converting here keeps the DateTime
    /// field type identical (`String`) across JSON and binary modes, matching the
    /// TS/Dart/Kotlin SDKs.
    public mutating func readDateTime() -> String {
        return Decoder.dateTimeString(fromUnixSeconds: readSvarint())
    }

    /// Read a nullable DateTime field (null flag + svarint(unix seconds)) → `String?`.
    public mutating func readDateTimePtr() -> String? {
        if !readNullFlag() { return nil }
        return Decoder.dateTimeString(fromUnixSeconds: readSvarint())
    }

    /// Format unix seconds as an RFC3339/ISO-8601 UTC string (e.g. `2021-07-14T02:40:00Z`).
    static func dateTimeString(fromUnixSeconds seconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        return date.formatted(Decoder.iso8601Format)
    }

    private static let iso8601Format = Date.ISO8601FormatStyle(timeZone: .gmt)

    /// Skip the arena header (totalStringLen varint) that prefixes each model's binary data.
    public mutating func skipArenaHeader() {
        _ = readVarint()
    }

    /// Read next field ID. Returns 0 for end marker.
    public mutating func nextField() -> Int {
        guard !isAtEnd else { return 0 }
        let rawID = readVarint()
        guard error == nil, rawID <= UInt64(Int.max) else {
            if error == nil { error = "field ID exceeds platform integer range" }
            return 0
        }
        return Int(rawID)
    }

    // MARK: - Nullable Readers

    /// Read nullable flag byte. Returns true if value is present (0x01).
    private mutating func readNullFlag() -> Bool {
        return readCanonicalMarker("nullable")
    }

    private mutating func readCanonicalMarker(_ kind: String) -> Bool {
        guard offset < data.count else {
            if error == nil { error = "truncated \(kind) marker at offset \(offset)" }
            return false
        }
        let markerOffset = offset
        let marker = data[offset]
        offset += 1
        switch marker {
        case 0x00:
            return false
        case 0x01:
            return true
        default:
            if error == nil { error = "invalid \(kind) marker at offset \(markerOffset)" }
            return false
        }
    }

    /// Read a nullable Int64 (null flag + zigzag varint).
    public mutating func readIntPtr() -> Int64? {
        if !readNullFlag() { return nil }
        return readSvarint()
    }

    /// Read a nullable Double (null flag + fixed64).
    public mutating func readFloatPtr() -> Double? {
        if !readNullFlag() { return nil }
        return readFixed64()
    }

    /// Read a nullable String (null flag + length-prefixed UTF-8).
    public mutating func readStringPtr() -> String? {
        if !readNullFlag() { return nil }
        return readString()
    }

    /// Read a nullable Bool (null flag + bool byte).
    public mutating func readBoolPtr() -> Bool? {
        if !readNullFlag() { return nil }
        return readBool()
    }

    public mutating func readNullable<T>(_ decode: (inout Decoder) throws -> T) rethrows -> T? {
        if !readNullFlag() { return nil }
        return try decode(&self)
    }

    // MARK: - Array Reader

    /// Read an array of items using a decoder closure.
    /// Format: varint count, then count items decoded by the closure.
    public mutating func readArray<T>(_ decode: (inout Decoder) throws -> T) rethrows -> [T] {
        let rawCount = readVarint()
        guard error == nil, rawCount <= CodecLimits.maxArrayElements else {
            if error == nil { error = "array count \(rawCount) exceeds limit \(CodecLimits.maxArrayElements)" }
            return []
        }
        let count = Int(rawCount)
        var items: [T] = []
        items.reserveCapacity(count)
        for _ in 0..<count {
            items.append(try decode(&self))
        }
        return items
    }
}

// MARK: - ColumnarDecoder

/// Columnar binary decoder for Luxo list responses.
///
/// Columnar format:
/// ```
/// [count varint]
/// [arena size varint]
/// [fieldID varint][val0][val1]...[valN]  // column 1
/// [fieldID varint][val0][val1]...[valN]  // column 2
/// ...
/// [0x00]  // end marker
/// ```
public struct ColumnarDecoder {
    private let data: Data
    private var off: Int = 0

    /// Number of rows in this columnar batch.
    public private(set) var count: Int = 0

    /// Total UTF-8 string bytes advertised for arena allocation.
    public private(set) var arenaSize: Int = 0

    /// The current column's field ID after calling [nextColumn].
    public private(set) var fieldID: Int = 0

    /// The first wire-format error encountered while decoding.
    public private(set) var error: String?

    /// Creates a columnar decoder from raw bytes. Reads the row count varint.
    public init(data: Data) {
        self.data = data
        guard let rawCount = readVarintValue("columnar record count") else { return }
        guard rawCount <= CodecLimits.maxColumnarRecords else {
            fail("columnar count \(rawCount) exceeds limit \(CodecLimits.maxColumnarRecords)")
            return
        }
        count = Int(rawCount)

        guard let rawArenaSize = readVarintValue("columnar arena size") else { return }
        guard rawArenaSize <= CodecLimits.maxArenaSize else {
            fail("columnar arena size \(rawArenaSize) exceeds limit \(CodecLimits.maxArenaSize)")
            return
        }
        arenaSize = Int(rawArenaSize)
    }

    /// Advance to next column. Returns false at end marker (0x00) or EOF.
    public mutating func nextColumn() -> Bool {
        if error != nil { return false }
        guard off < data.count else {
            fail("missing columnar end marker at offset \(off)")
            return false
        }
        guard let rawID = readVarintValue("column field ID") else { return false }
        if rawID == 0 {
            fieldID = 0
            return false
        }
        guard rawID <= UInt64(Int.max) else {
            fail("column field ID exceeds platform integer range")
            return false
        }
        fieldID = Int(rawID)
        return true
    }

    /// Read `count` zigzag-encoded signed int64 values.
    public mutating func readColumnInt() -> [Int64] {
        readColumn("int") { decoder, index in
            decoder.readSvarintValue("int column at record \(index)")
        }
    }

    /// Read `count` fixed64 (8-byte LE) float values.
    public mutating func readColumnFloat() -> [Double] {
        readColumn("float") { decoder, index in
            decoder.readFixed64Value("float column at record \(index)")
        }
    }

    /// Read `count` length-prefixed UTF-8 string values.
    public mutating func readColumnString() -> [String] {
        readColumn("string") { decoder, index in
            decoder.readStringValue("string column at record \(index)")
        }
    }

    /// Read `count` boolean values (varint 0/1).
    public mutating func readColumnBool() -> [Bool] {
        readColumn("bool") { decoder, index in
            decoder.readMarker("bool column at record \(index)")
        }
    }

    /// Read `count` nullable int values (0x00=null, 0x01+svarint).
    public mutating func readColumnIntPtr() -> [Int64?] {
        readNullableColumn("int") { decoder, index in
            decoder.readSvarintValue("nullable int value at record \(index)")
        }
    }

    /// Read `count` nullable float values (0x00=null, 0x01+fixed64).
    public mutating func readColumnFloatPtr() -> [Double?] {
        readNullableColumn("float") { decoder, index in
            decoder.readFixed64Value("nullable float value at record \(index)")
        }
    }

    /// Read `count` nullable string values (0x00=null, 0x01+string).
    public mutating func readColumnStringPtr() -> [String?] {
        readNullableColumn("string") { decoder, index in
            decoder.readStringValue("nullable string value at record \(index)")
        }
    }

    /// Read `count` nullable boolean values (0x00=null, 0x01+varint).
    public mutating func readColumnBoolPtr() -> [Bool?] {
        readNullableColumn("bool") { decoder, index in
            decoder.readMarker("nullable bool value at record \(index)")
        }
    }

    /// Read `count` fixed 16-byte UUID values.
    public mutating func readColumnUUID() -> [UUID] {
        readColumn("UUID") { decoder, index in
            decoder.readUUIDValue("UUID column at record \(index)")
        }
    }

    /// Read `count` nullable UUID values (0x00=null, 0x01+16 bytes).
    public mutating func readColumnUUIDPtr() -> [UUID?] {
        readNullableColumn("UUID") { decoder, index in
            decoder.readUUIDValue("nullable UUID value at record \(index)")
        }
    }

    /// Read `count` length-prefixed byte blobs.
    /// Used for scalar array-field columns: each cell is an inline `[count][items...]`
    /// array wrapped as a length-prefixed blob.
    public mutating func readColumnBytes() -> [Data] {
        readColumn("bytes") { decoder, index in
            decoder.readBytesValue("bytes column at record \(index)")
        }
    }

    /// Read `count` nullable byte blobs (0x00=null, 0x01+length+bytes).
    public mutating func readColumnBytesPtr() -> [Data?] {
        readNullableColumn("bytes") { decoder, index in
            decoder.readBytesValue("nullable bytes value at record \(index)")
        }
    }

    /// Read `count` DateTime values (svarint unix seconds) as RFC3339/ISO-8601 strings.
    /// DateTime columns are Int columns on the wire; convert to match JSON mode.
    public mutating func readColumnDateTime() -> [String] {
        let seconds = readColumnInt()
        return seconds.map { Decoder.dateTimeString(fromUnixSeconds: $0) }
    }

    /// Read `count` nullable DateTime values (0x00=null, 0x01+svarint seconds) as `String?`.
    public mutating func readColumnDateTimePtr() -> [String?] {
        let seconds = readColumnIntPtr()
        return seconds.map { $0.map { Decoder.dateTimeString(fromUnixSeconds: $0) } }
    }

    /// Current read position (for reading pagination metadata after 0x00).
    public var offset: Int { off }

    /// Read one signed zigzag-encoded varint at current position.
    public mutating func readSvarint() -> Int64 {
        readSvarintValue("signed varint") ?? 0
    }

    // MARK: - Internal

    private mutating func readColumn<T>(
        _ name: String,
        read: (inout ColumnarDecoder, Int) -> T?
    ) -> [T] {
        guard error == nil else { return [] }
        var result: [T] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            guard let value = read(&self, index) else {
                fail("invalid \(name) column at record \(index)")
                return []
            }
            result.append(value)
        }
        return result
    }

    private mutating func readNullableColumn<T>(
        _ name: String,
        read: (inout ColumnarDecoder, Int) -> T?
    ) -> [T?] {
        guard error == nil else { return [] }
        var result: [T?] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            guard let present = readMarker("nullable \(name) marker at record \(index)") else { return [] }
            guard present else {
                result.append(nil)
                continue
            }
            guard let value = read(&self, index) else { return [] }
            result.append(value)
        }
        return result
    }

    private mutating func readVarintValue(_ context: String) -> UInt64? {
        let start = off
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while off < data.count {
            let byte = data[off]
            off += 1
            if shift >= 64 || (shift == 63 && byte & 0x7E != 0) {
                fail("varint overflow in \(context) at offset \(start)")
                return nil
            }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        fail("truncated varint in \(context) at offset \(start)")
        return nil
    }

    private mutating func readSvarintValue(_ context: String) -> Int64? {
        guard let value = readVarintValue(context) else { return nil }
        return Int64(bitPattern: (value >> 1) ^ UInt64(bitPattern: -Int64(value & 1)))
    }

    private mutating func readFixed64Value(_ context: String) -> Double? {
        guard off <= data.count, data.count - off >= 8 else {
            fail("truncated \(context) at offset \(off)")
            return nil
        }
        let bits = data[off..<off + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        off += 8
        return Double(bitPattern: bits)
    }

    private mutating func readBytesValue(_ context: String) -> Data? {
        guard let rawLength = readVarintValue("\(context) length"), rawLength <= UInt64(Int.max) else {
            if error == nil { fail("\(context) length exceeds platform integer range") }
            return nil
        }
        let length = Int(rawLength)
        guard off <= data.count, length <= data.count - off else {
            fail("truncated \(context) at offset \(off)")
            return nil
        }
        let result = Data(data[off..<off + length])
        off += length
        return result
    }

    private mutating func readStringValue(_ context: String) -> String? {
        let start = off
        guard let bytes = readBytesValue(context) else { return nil }
        guard let value = String(data: bytes, encoding: .utf8) else {
            fail("invalid UTF-8 in \(context) at offset \(start)")
            return nil
        }
        return value
    }

    private mutating func readMarker(_ context: String) -> Bool? {
        guard off < data.count else {
            fail("truncated \(context) at offset \(off)")
            return nil
        }
        let markerOffset = off
        let marker = data[off]
        off += 1
        switch marker {
        case 0x00:
            return false
        case 0x01:
            return true
        default:
            fail("invalid \(context) at offset \(markerOffset)")
            return nil
        }
    }

    private mutating func readUUIDValue(_ context: String) -> UUID? {
        guard off <= data.count, data.count - off >= 16 else {
            fail("truncated \(context) at offset \(off)")
            return nil
        }
        let a = Array(data[off..<off + 16])
        off += 16
        return UUID(
            uuid: (
                a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7],
                a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15]
            ))
    }

    private mutating func fail(_ message: String) {
        if error == nil { error = message }
    }
}

// MARK: - FieldMask

/// Set a field as selected in a bitmask.
public func fieldMaskSet(_ mask: inout [UInt8], fieldID: Int) {
    guard fieldID > 0 else { return }
    let bit = fieldID - 1
    let byteIndex = bit / 8
    let bitIndex = bit % 8
    while mask.count <= byteIndex {
        mask.append(0)
    }
    mask[byteIndex] |= (1 << bitIndex)
}

/// Check if a field is selected in a bitmask.
public func fieldMaskHas(_ mask: [UInt8], fieldID: Int) -> Bool {
    guard fieldID > 0 else { return false }
    let bit = fieldID - 1
    let byteIndex = bit / 8
    let bitIndex = bit % 8
    guard byteIndex < mask.count else { return false }
    return mask[byteIndex] & (1 << bitIndex) != 0
}
