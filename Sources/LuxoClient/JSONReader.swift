import Foundation

/// A single UTF-8 pass; numbers are never routed through Foundation numeric objects.
struct JSONReader {
    let bytes: UnsafeBufferPointer<UInt8>
    var offset = 0

    static func decode(_ data: Data) throws -> LuxoValue {
        try data.withUnsafeBytes { raw in
            var reader = JSONReader(bytes: raw.bindMemory(to: UInt8.self))
            // A document BOM is accepted; a BOM inside a string remains string content.
            if reader.bytes.starts(with: [0xef, 0xbb, 0xbf]) { reader.offset = 3 }
            let result = try reader.value(depth: 0)
            reader.whitespace()
            guard reader.offset == raw.count else { throw reader.invalid() }
            return result
        }
    }

    func invalid() -> LuxoError {
        LuxoError(code: 0, message: "invalid JSON at byte \(offset)", name: "ParseError")
    }

    var current: UInt8 { offset < bytes.count ? bytes[offset] : 0 }

    mutating func take(_ byte: UInt8) -> Bool {
        guard offset < bytes.count, current == byte else { return false }
        offset += 1
        return true
    }

    mutating func whitespace() {
        while offset < bytes.count {
            switch current {
            case 9, 10, 13, 32: offset += 1
            default: return
            }
        }
    }

    mutating func value(depth: Int) throws -> LuxoValue {
        guard depth <= 128 else { throw invalid() }
        whitespace()
        switch current {
        case 34: return .string(try string())
        case 91: return try array(depth: depth)
        case 123: return try object(depth: depth)
        case 110: try keyword("null"); return .null
        case 116: try keyword("true"); return .bool(true)
        case 102: try keyword("false"); return .bool(false)
        default: return try number()
        }
    }

    mutating func keyword(_ word: StaticString) throws {
        let matched = word.withUTF8Buffer { token in
            guard bytes.count - offset >= token.count else { return false }
            return bytes[offset..<(offset + token.count)].elementsEqual(token)
        }
        guard matched else { throw invalid() }
        offset += word.utf8CodeUnitCount
    }

    mutating func number() throws -> LuxoValue {
        let token = try numberToken()
        let literal = String(decoding: bytes[token.range], as: UTF8.self)
        if token.integral, literal != "-0", let integer = Int64(literal) { return .int(integer) }
        return .jsonNumber(JSONNumber(validated: literal))
    }

    mutating func numberToken() throws -> (range: Range<Int>, integral: Bool) {
        let start = offset
        _ = take(45)
        if !take(48) {
            guard current >= 49 && current <= 57 else { throw invalid() }
            digits()
        }
        var integral = true
        if take(46) {
            integral = false
            try requiredDigits()
        }
        if take(101) || take(69) {
            integral = false
            if !take(43) { _ = take(45) }
            try requiredDigits()
        }
        return (start..<offset, integral)
    }

    private mutating func digits() {
        while current >= 48 && current <= 57 { offset += 1 }
    }

    private mutating func requiredDigits() throws {
        guard current >= 48 && current <= 57 else { throw invalid() }
        digits()
    }

    private mutating func array(depth: Int) throws -> LuxoValue {
        offset += 1
        whitespace()
        var values: [LuxoValue] = []
        if take(93) { return .array(values) }
        repeat {
            guard values.count < 1_000_000 else { throw invalid() }
            values.append(try value(depth: depth + 1))
            whitespace()
            if take(93) { return .array(values) }
            guard take(44) else { throw invalid() }
        } while true
    }

    private mutating func object(depth: Int) throws -> LuxoValue {
        offset += 1
        whitespace()
        var values: [String: LuxoValue] = [:]
        if take(125) { return .object(values) }
        repeat {
            whitespace()
            let key = try string()
            whitespace()
            guard take(58) else { throw invalid() }
            values[key] = try value(depth: depth + 1)
            whitespace()
            if take(125) { return .object(values) }
            guard take(44) else { throw invalid() }
        } while true
    }

    mutating func string() throws -> String {
        guard take(34) else { throw invalid() }
        let start = offset
        advanceStringSegment()
        if current == 34 {
            let result = try utf8(start..<offset)
            offset += 1
            return result
        }
        if current == 92 { return try escapedString(start: start) }
        throw invalid()
    }

    // Locate structural bytes only; callers still validate UTF-8 and Unicode escapes.
    @inline(__always)
    mutating func advanceStringSegment() {
        let raw = UnsafeRawBufferPointer(bytes)
        var cursor = offset
        // Repeated-byte masks work in either endian order; only detect existence, not a byte position.
        // Borrow can mark adjacent lanes too, so the scalar tail locates the first actual delimiter.
        // The bounded unaligned load must never include bytes beyond the input slice.
        while bytes.count - cursor >= 8 {
            let word = raw.loadUnaligned(fromByteOffset: cursor, as: UInt64.self)
            let quote = word ^ 0x2222_2222_2222_2222
            let escape = word ^ 0x5c5c_5c5c_5c5c_5c5c
            let controls = (word &- 0x2020_2020_2020_2020) & ~word
            let quotes = (quote &- 0x0101_0101_0101_0101) & ~quote
            let escapes = (escape &- 0x0101_0101_0101_0101) & ~escape
            if (controls | quotes | escapes) & 0x8080_8080_8080_8080 != 0 { break }
            cursor += 8
        }
        while cursor < bytes.count {
            let byte = bytes[cursor]
            if byte < 32 || byte == 34 || byte == 92 { break }
            cursor += 1
        }
        offset = cursor
    }

    private func utf8(_ range: Range<Int>) throws -> String {
        if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, *) {
            guard let value = String(validating: bytes[range], as: UTF8.self) else { throw invalid() }
            return value
        }
        return try legacyUTF8(range)
    }

    // Foundation treats a leading BOM as an encoding marker even inside a JSON string.
    func legacyUTF8(_ range: Range<Int>) throws -> String {
        guard let value = String(bytes: bytes[range], encoding: .utf8) else { throw invalid() }
        if bytes[range].starts(with: [0xef, 0xbb, 0xbf]) { return "\u{feff}" + value }
        return value
    }

    private mutating func escapedString(start: Int) throws -> String {
        var result = try utf8(start..<offset)
        repeat {
            guard take(92) else { throw invalid() }
            result.unicodeScalars.append(try escapedScalar())
            let segment = offset
            advanceStringSegment()
            if segment < offset { result += try utf8(segment..<offset) }
            if take(34) { return result }
        } while true
    }

    mutating func escapedScalar() throws -> Unicode.Scalar {
        let byte = current
        guard offset < bytes.count else { throw invalid() }
        offset += 1
        switch byte {
        case 34: return "\""
        case 47: return "/"
        case 92: return "\\"
        case 98: return "\u{8}"
        case 102: return "\u{c}"
        case 110: return "\n"
        case 114: return "\r"
        case 116: return "\t"
        case 117:
            var code = try hexQuad()
            if code >= 0xd800 && code <= 0xdbff {
                guard take(92), take(117) else { throw invalid() }
                let low = try hexQuad()
                guard low >= 0xdc00 && low <= 0xdfff else { throw invalid() }
                code = 0x10000 + ((code - 0xd800) << 10) + low - 0xdc00
            }
            guard let scalar = Unicode.Scalar(code) else { throw invalid() }
            return scalar
        default: throw invalid()
        }
    }

    private mutating func hexQuad() throws -> UInt32 {
        guard bytes.count - offset >= 4 else { throw invalid() }
        var result: UInt32 = 0
        for _ in 0..<4 {
            let digit: UInt8
            switch current {
            case 48...57: digit = current - 48
            case 65...70: digit = current - 55
            case 97...102: digit = current - 87
            default: throw invalid()
            }
            result = result * 16 + UInt32(digit)
            offset += 1
        }
        return result
    }
}
