import Foundation

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

    public mutating func writeField(_ fieldID: Int, value: Any, type: String) {
        writeVarint(UInt64(fieldID))
        switch type {
        case "Int", "Duration":
            writeSvarint(value as? Int64 ?? Int64(value as? Int ?? 0))
        case "Float":
            writeFixed64(value as? Double ?? 0)
        case "Boolean":
            writeBool(value as? Bool ?? false)
        case "UUID":
            // UUID is a fixed 16-byte value; accept Foundation.UUID or canonical string.
            if let u = value as? UUID {
                writeUUID(u)
            } else if let s = value as? String, let u = UUID(uuidString: s) {
                writeUUID(u)
            } else {
                writeUUID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
            }
        case "String", "Enum", "Decimal":
            writeString(value as? String ?? "")
        case "DateTime":
            // Per protocol: DateTime = svarint(unix seconds). Accept Date or ISO string.
            let sec: Int64
            if let d = value as? Date {
                sec = Int64(d.timeIntervalSince1970)
            } else if let s = value as? String,
                      let d = ISO8601DateFormatter().date(from: s) {
                sec = Int64(d.timeIntervalSince1970)
            } else if let i = value as? Int64 {
                sec = i
            } else {
                sec = 0
            }
            writeSvarint(sec)
        default:
            break
        }
    }

    /// Write a list param field: [fieldID][varint count][item0][item1]...
    /// Each item is encoded by its element type (no per-item field ID).
    public mutating func writeFieldList(_ fieldID: Int, values: [Any], type: String) {
        writeVarint(UInt64(fieldID))
        writeArrayHeader(values.count)
        for value in values {
            switch type {
            case "Int", "Duration", "DateTime":
                writeSvarint(value as? Int64 ?? Int64(value as? Int ?? 0))
            case "Float":
                writeFixed64(value as? Double ?? 0)
            case "Boolean":
                writeBool(value as? Bool ?? false)
            case "UUID":
                if let u = value as? UUID {
                    writeUUID(u)
                } else if let s = value as? String, let u = UUID(uuidString: s) {
                    writeUUID(u)
                } else {
                    writeUUID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
                }
            case "Bytes":
                writeBytes(value as? Data ?? Data())
            default:
                writeString(value as? String ?? "")
            }
        }
    }
}

// MARK: - Decoder

/// Binary decoder for Luxo protocol.
public struct Decoder {
    private let data: Data
    private var offset: Int = 0

    public init(_ data: Data) {
        self.data = data
    }

    public var isAtEnd: Bool { offset >= data.count }

    public mutating func readVarint() -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        return result
    }

    public mutating func readSvarint() -> Int64 {
        let n = readVarint()
        // ZigZag decode: (n >> 1) ^ -(n & 1)
        return Int64(bitPattern: (n >> 1) ^ (UInt64(bitPattern: -Int64(n & 1))))
    }

    public mutating func readFixed64() -> Double {
        guard offset + 8 <= data.count else { return 0 }
        let bits = data[offset..<offset+8].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        offset += 8
        return Double(bitPattern: bits)
    }

    public mutating func readBool() -> Bool {
        guard offset < data.count else { return false }
        let v = data[offset]
        offset += 1
        return v != 0
    }

    public mutating func readString() -> String {
        let len = Int(readVarint())
        guard offset + len <= data.count else { return "" }
        let str = String(data: data[offset..<offset+len], encoding: .utf8) ?? ""
        offset += len
        return str
    }

    public mutating func readBytes() -> Data {
        let len = Int(readVarint())
        guard offset + len <= data.count else { return Data() }
        let bytes = data[offset..<offset+len]
        offset += len
        return Data(bytes)
    }

    /// Read a fixed 16-byte UUID (no length prefix). Returns a zero UUID on truncation.
    public mutating func readUUID() -> UUID {
        guard offset + 16 <= data.count else {
            return UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        }
        let b = data[offset..<offset+16]
        offset += 16
        let a = Array(b)
        return UUID(uuid: (
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
        return Decoder.iso8601Formatter.string(from: date)
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    /// Skip the arena header (totalStringLen varint) that prefixes each model's binary data.
    public mutating func skipArenaHeader() {
        _ = readVarint()
    }

    /// Read next field ID. Returns 0 for end marker.
    public mutating func nextField() -> Int {
        guard !isAtEnd else { return 0 }
        let id = Int(readVarint())
        return id
    }

    // MARK: - Nullable Readers

    /// Read nullable flag byte. Returns true if value is present (0x01).
    private mutating func readNullFlag() -> Bool {
        guard offset < data.count else { return false }
        let flag = data[offset]
        offset += 1
        return flag != 0x00
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

    // MARK: - Array Reader

    /// Read an array of items using a decoder closure.
    /// Format: varint count, then count items decoded by the closure.
    public mutating func readArray<T>(_ decode: (inout Decoder) -> T) -> [T] {
        let count = Int(readVarint())
        var items: [T] = []
        items.reserveCapacity(count)
        for _ in 0..<count {
            items.append(decode(&self))
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

    /// The current column's field ID after calling [nextColumn].
    public private(set) var fieldID: Int = 0

    /// Creates a columnar decoder from raw bytes. Reads the row count varint.
    public init(data: Data) {
        self.data = data
        self.count = Int(readVarintInternal())
    }

    /// Advance to next column. Returns false at end marker (0x00) or EOF.
    public mutating func nextColumn() -> Bool {
        if off >= data.count { return false }
        let id = Int(readVarintInternal())
        fieldID = id
        return id != 0
    }

    /// Read `count` zigzag-encoded signed int64 values.
    public mutating func readColumnInt() -> [Int64] {
        var result = [Int64]()
        result.reserveCapacity(count)
        for _ in 0..<count {
            let n = readVarintInternal()
            result.append(Int64(bitPattern: (n >> 1) ^ (UInt64(bitPattern: -Int64(n & 1)))))
        }
        return result
    }

    /// Read `count` fixed64 (8-byte LE) float values.
    public mutating func readColumnFloat() -> [Double] {
        var result = [Double]()
        result.reserveCapacity(count)
        for _ in 0..<count {
            guard off + 8 <= data.count else { result.append(0); continue }
            let bits = data[off..<off+8].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            off += 8
            result.append(Double(bitPattern: bits))
        }
        return result
    }

    /// Read `count` length-prefixed UTF-8 string values.
    public mutating func readColumnString() -> [String] {
        var result = [String]()
        result.reserveCapacity(count)
        for _ in 0..<count {
            let len = Int(readVarintInternal())
            if len == 0 { result.append(""); continue }
            guard off + len <= data.count else { result.append(""); continue }
            let str = String(data: data[off..<off+len], encoding: .utf8) ?? ""
            off += len
            result.append(str)
        }
        return result
    }

    /// Read `count` boolean values (varint 0/1).
    public mutating func readColumnBool() -> [Bool] {
        var result = [Bool]()
        result.reserveCapacity(count)
        for _ in 0..<count {
            result.append(readVarintInternal() != 0)
        }
        return result
    }

    /// Read `count` nullable int values (0x00=null, 0x01+svarint).
    public mutating func readColumnIntPtr() -> [Int64?] {
        var result = [Int64?]()
        result.reserveCapacity(count)
        for _ in 0..<count {
            guard off < data.count else { result.append(nil); continue }
            let flag = data[off]; off += 1
            if flag == 0x00 { result.append(nil); continue }
            let n = readVarintInternal()
            result.append(Int64(bitPattern: (n >> 1) ^ (UInt64(bitPattern: -Int64(n & 1)))))
        }
        return result
    }

    /// Read `count` nullable float values (0x00=null, 0x01+fixed64).
    public mutating func readColumnFloatPtr() -> [Double?] {
        var result = [Double?]()
        result.reserveCapacity(count)
        for _ in 0..<count {
            guard off < data.count else { result.append(nil); continue }
            let flag = data[off]; off += 1
            if flag == 0x00 { result.append(nil); continue }
            guard off + 8 <= data.count else { result.append(nil); continue }
            let bits = data[off..<off+8].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            off += 8
            result.append(Double(bitPattern: bits))
        }
        return result
    }

    /// Read `count` nullable string values (0x00=null, 0x01+string).
    public mutating func readColumnStringPtr() -> [String?] {
        var result = [String?]()
        result.reserveCapacity(count)
        for _ in 0..<count {
            guard off < data.count else { result.append(nil); continue }
            let flag = data[off]; off += 1
            if flag == 0x00 { result.append(nil); continue }
            let len = Int(readVarintInternal())
            if len == 0 { result.append(""); continue }
            guard off + len <= data.count else { result.append(nil); continue }
            let str = String(data: data[off..<off+len], encoding: .utf8) ?? ""
            off += len
            result.append(str)
        }
        return result
    }

    /// Read `count` nullable boolean values (0x00=null, 0x01+varint).
    public mutating func readColumnBoolPtr() -> [Bool?] {
        var result = [Bool?]()
        result.reserveCapacity(count)
        for _ in 0..<count {
            guard off < data.count else { result.append(nil); continue }
            let flag = data[off]; off += 1
            if flag == 0x00 { result.append(nil); continue }
            result.append(readVarintInternal() != 0)
        }
        return result
    }

    /// Read `count` fixed 16-byte UUID values.
    public mutating func readColumnUUID() -> [UUID] {
        var result = [UUID]()
        result.reserveCapacity(count)
        for _ in 0..<count {
            result.append(readUUIDInternal())
        }
        return result
    }

    /// Read `count` nullable UUID values (0x00=null, 0x01+16 bytes).
    public mutating func readColumnUUIDPtr() -> [UUID?] {
        var result = [UUID?]()
        result.reserveCapacity(count)
        for _ in 0..<count {
            guard off < data.count else { result.append(nil); continue }
            let flag = data[off]; off += 1
            if flag == 0x00 { result.append(nil); continue }
            result.append(readUUIDInternal())
        }
        return result
    }

    /// Read `count` length-prefixed byte blobs.
    /// Used for scalar array-field columns: each cell is an inline `[count][items...]`
    /// array wrapped as a length-prefixed blob.
    public mutating func readColumnBytes() -> [Data] {
        var result = [Data]()
        result.reserveCapacity(count)
        for _ in 0..<count {
            let len = Int(readVarintInternal())
            if len == 0 { result.append(Data()); continue }
            guard off + len <= data.count else { result.append(Data()); continue }
            let bytes = data[off..<off+len]
            off += len
            result.append(Data(bytes))
        }
        return result
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
        let n = readVarintInternal()
        return Int64(bitPattern: (n >> 1) ^ (UInt64(bitPattern: -Int64(n & 1))))
    }

    // MARK: - Internal

    private mutating func readVarintInternal() -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while off < data.count {
            let byte = data[off]
            off += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        return result
    }

    /// Read a fixed 16-byte UUID at the current position. Zero UUID on truncation.
    private mutating func readUUIDInternal() -> UUID {
        guard off + 16 <= data.count else {
            return UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        }
        let a = Array(data[off..<off+16])
        off += 16
        return UUID(uuid: (
            a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7],
            a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15]
        ))
    }
}

// MARK: - FieldMask

/// Set a field as selected in a bitmask.
public func fieldMaskSet(_ mask: inout [UInt8], fieldID: Int) {
    let byteIndex = fieldID / 8
    let bitIndex = fieldID % 8
    while mask.count <= byteIndex {
        mask.append(0)
    }
    mask[byteIndex] |= (1 << bitIndex)
}

/// Check if a field is selected in a bitmask.
public func fieldMaskHas(_ mask: [UInt8], fieldID: Int) -> Bool {
    let byteIndex = fieldID / 8
    let bitIndex = fieldID % 8
    guard byteIndex < mask.count else { return false }
    return mask[byteIndex] & (1 << bitIndex) != 0
}
