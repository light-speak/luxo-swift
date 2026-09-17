import Foundation

/// Validated transport metadata plus the untouched JSON payload, not a second object tree.
struct JSONEnvelope {
    let fields: [String: LuxoValue]
    // Capture control-key presence during parsing, avoiding a second hash lookup per frame.
    let hasTerminalMetadata: Bool
    private let source: Data
    private let payload: Range<Int>?

    var hasData: Bool { payload != nil }

    var responseData: Data {
        guard let payload else { return Data("null".utf8) }
        // Data slices can have a nonzero startIndex; reader offsets are always relative.
        return source[(source.startIndex + payload.lowerBound)..<(source.startIndex + payload.upperBound)]
    }

    static func decode(_ data: Data, errorResponse: Bool = false) throws -> JSONEnvelope {
        try data.withUnsafeBytes { raw in
            var reader = JSONReader(bytes: raw.bindMemory(to: UInt8.self))
            if reader.bytes.starts(with: [0xef, 0xbb, 0xbf]) { reader.offset = 3 }
            let (fields, range, terminal) = try reader.envelope(errorResponse: errorResponse)
            reader.whitespace()
            guard reader.offset == raw.count else { throw reader.invalid() }
            return JSONEnvelope(fields: fields, hasTerminalMetadata: terminal, source: data, payload: range)
        }
    }

    func materializedFields() throws -> [String: LuxoValue] {
        var values = fields
        if payload != nil, values["data"] == nil { values["data"] = try JSONReader.decode(responseData) }
        return values
    }

    static func decodeError(_ envelope: JSONEnvelope, statusCode: Int) -> LuxoError {
        do {
            return LuxoError.fromResponse(values: try envelope.materializedFields(), statusCode: statusCode)
        } catch {
            // Defensive: decode already validated this immutable slice, including depth/count limits.
            return LuxoError(code: statusCode, message: "invalid JSON error response", name: "ParseError")
        }
    }
}

extension JSONReader {
    fileprivate mutating func envelope(errorResponse: Bool) throws -> ([String: LuxoValue], Range<Int>?, Bool) {
        whitespace()
        guard take(123) else { throw invalid() }
        var fields: [String: LuxoValue] = [:]
        var payload: Range<Int>?
        var terminal = false
        whitespace()
        if take(125) { return (fields, payload, terminal) }
        repeat {
            whitespace()
            let key = try string()
            whitespace()
            guard take(58) else { throw invalid() }
            whitespace()
            switch key {
            case "data":
                let start = offset
                if errorResponse || fields["error"] != nil {
                    fields[key] = try value(depth: 1)
                } else {
                    try skipValue(depth: 1)
                }
                payload = start..<offset
            case "$end":
                terminal = true
                fields[key] = try value(depth: 1)
            case "$id", "$sub", "$stream", "ok", "error", "code", "message", "traceId", "cause":
                fields[key] = try value(depth: 1)
            default:
                try skipValue(depth: 1)
            }
            whitespace()
            if take(125) { return (fields, payload, terminal) }
            guard take(44) else { throw invalid() }
        } while true
    }

    private mutating func skipValue(depth: Int) throws {
        guard depth <= 128 else { throw invalid() }
        whitespace()
        switch current {
        case 34: try skipString()
        case 91: try skipArray(depth: depth)
        case 123: try skipObject(depth: depth)
        case 110: try keyword("null")
        case 116: try keyword("true")
        case 102: try keyword("false")
        default: _ = try numberToken()
        }
    }

    private mutating func skipArray(depth: Int) throws {
        offset += 1
        whitespace()
        if take(93) { return }
        var count = 0
        repeat {
            guard count < 1_000_000 else { throw invalid() }
            count += 1
            try skipValue(depth: depth + 1)
            whitespace()
            if take(93) { return }
            guard take(44) else { throw invalid() }
        } while true
    }

    private mutating func skipObject(depth: Int) throws {
        offset += 1
        whitespace()
        if take(125) { return }
        repeat {
            whitespace()
            try skipString()
            whitespace()
            guard take(58) else { throw invalid() }
            try skipValue(depth: depth + 1)
            whitespace()
            if take(125) { return }
            guard take(44) else { throw invalid() }
        } while true
    }

    private mutating func skipString() throws {
        guard take(34) else { throw invalid() }
        let start = offset
        repeat {
            advanceStringSegment()
            if take(34) {
                try validateUTF8(start..<(offset - 1))
                return
            }
            guard take(92) else { throw invalid() }
            _ = try escapedScalar()
        } while true
    }

    private func validateUTF8(_ range: Range<Int>) throws {
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            do { _ = try UTF8Span(validating: UnsafeBufferPointer(rebasing: bytes[range]).span) } catch {
                throw invalid()
            }
        } else {
            try validateLegacyUTF8(range)
        }
    }

    // Keep the same strict check on older devices without allocating a temporary String.
    func validateLegacyUTF8(_ range: Range<Int>) throws {
        var iterator = bytes[range].makeIterator()
        var decoder = Unicode.UTF8()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue: continue
            case .emptyInput: return
            case .error: throw invalid()
            }
        }
    }
}
