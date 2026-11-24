import Foundation

/// Validated transport metadata plus the untouched JSON payload, not a second object tree.
struct PreTerminalJSONEnvelope {
    let fields: [String: LuxoValue]
    private let source: Data
    private let payload: Range<Int>?

    var responseData: Data {
        guard let payload else { return Data("null".utf8) }
        // Data slices can have a nonzero startIndex; reader offsets are always relative.
        return source[(source.startIndex + payload.lowerBound)..<(source.startIndex + payload.upperBound)]
    }

    static func decode(_ data: Data, errorResponse: Bool = false) throws -> PreTerminalJSONEnvelope {
        try data.withUnsafeBytes { raw in
            var reader = JSONReader(bytes: raw.bindMemory(to: UInt8.self))
            if reader.bytes.starts(with: [0xef, 0xbb, 0xbf]) { reader.offset = 3 }
            let (fields, range) = try reader.preTerminalEnvelope(errorResponse: errorResponse)
            reader.whitespace()
            guard reader.offset == raw.count else { throw reader.invalid() }
            return PreTerminalJSONEnvelope(fields: fields, source: data, payload: range)
        }
    }

    func materializedFields() throws -> [String: LuxoValue] {
        var values = fields
        if payload != nil, values["data"] == nil { values["data"] = try JSONReader.decode(responseData) }
        return values
    }

    static func decodeError(_ preTerminalEnvelope: PreTerminalJSONEnvelope, statusCode: Int) -> LuxoError {
        do {
            return LuxoError.fromResponse(values: try preTerminalEnvelope.materializedFields(), statusCode: statusCode)
        } catch {
            // Defensive: decode already validated this immutable slice, including depth/count limits.
            return LuxoError(code: statusCode, message: "invalid JSON error response", name: "ParseError")
        }
    }
}

extension JSONReader {
    fileprivate mutating func preTerminalEnvelope(errorResponse: Bool) throws -> ([String: LuxoValue], Range<Int>?) {
        whitespace()
        guard take(123) else { throw invalid() }
        var fields: [String: LuxoValue] = [:]
        var payload: Range<Int>?
        whitespace()
        if take(125) { return (fields, payload) }
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
                    try preTerminalSkipValue(depth: 1)
                }
                payload = start..<offset
            case "$id", "$sub", "$stream", "ok", "error", "code", "message", "traceId", "cause":
                fields[key] = try value(depth: 1)
            default:
                try preTerminalSkipValue(depth: 1)
            }
            whitespace()
            if take(125) { return (fields, payload) }
            guard take(44) else { throw invalid() }
        } while true
    }

    private mutating func preTerminalSkipValue(depth: Int) throws {
        guard depth <= 128 else { throw invalid() }
        whitespace()
        switch current {
        case 34: try preTerminalSkipString()
        case 91: try preTerminalSkipArray(depth: depth)
        case 123: try preTerminalSkipObject(depth: depth)
        case 110: try keyword("null")
        case 116: try keyword("true")
        case 102: try keyword("false")
        default: _ = try numberToken()
        }
    }

    private mutating func preTerminalSkipArray(depth: Int) throws {
        offset += 1
        whitespace()
        if take(93) { return }
        var count = 0
        repeat {
            guard count < 1_000_000 else { throw invalid() }
            count += 1
            try preTerminalSkipValue(depth: depth + 1)
            whitespace()
            if take(93) { return }
            guard take(44) else { throw invalid() }
        } while true
    }

    private mutating func preTerminalSkipObject(depth: Int) throws {
        offset += 1
        whitespace()
        if take(125) { return }
        repeat {
            whitespace()
            try preTerminalSkipString()
            whitespace()
            guard take(58) else { throw invalid() }
            try preTerminalSkipValue(depth: depth + 1)
            whitespace()
            if take(125) { return }
            guard take(44) else { throw invalid() }
        } while true
    }

    private mutating func preTerminalSkipString() throws {
        guard take(34) else { throw invalid() }
        let start = offset
        repeat {
            advanceStringSegment()
            if take(34) {
                try preTerminalValidateUTF8(start..<(offset - 1))
                return
            }
            guard take(92) else { throw invalid() }
            _ = try escapedScalar()
        } while true
    }

    private func preTerminalValidateUTF8(_ range: Range<Int>) throws {
        if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
            do { _ = try UTF8Span(validating: UnsafeBufferPointer(rebasing: bytes[range]).span) } catch {
                throw invalid()
            }
        } else {
            try preTerminalValidateLegacyUTF8(range)
        }
    }

    // Keep the same strict check on older devices without allocating a temporary String.
    func preTerminalValidateLegacyUTF8(_ range: Range<Int>) throws {
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

enum PreTerminalWebSocketProtocol {
    struct SubscriptionAcknowledgement {
        let id: UInt64
        let error: LuxoError?
    }

    struct BinaryFrame {
        let type: UInt64
        let id: UInt64
        let payload: Data
    }

    static func jsonCallFrame(
        sequence: UInt64, api: String, params: [String: LuxoValue]?, plan: JSONParameterPlan? = nil
    ) throws -> Data {
        // Protocol metadata is uint64; schema Int/Duration values remain signed int64.
        return try LuxoJSONRequest.encode(api: api, params: params, plan: plan, sequence: sequence)
    }

    static func jsonRequestID(value: LuxoValue?) -> UInt64? {
        switch value {
        case .int(let number) where number >= 0: return UInt64(number)
        case .jsonNumber(let number) where number.isInteger && !number.literal.hasPrefix("-"):
            return UInt64(number.literal)
        default: return nil
        }
    }

    static func decodeJSONSubscriptionAcknowledgement(values: [String: LuxoValue]) -> SubscriptionAcknowledgement? {
        guard let id = jsonRequestID(value: values["$sub"]) else { return nil }
        if values["error"] != nil {
            return SubscriptionAcknowledgement(id: id, error: LuxoError.fromResponse(values: values, statusCode: 0))
        }
        guard case .bool(true) = values["ok"] else { return nil }
        return SubscriptionAcknowledgement(id: id, error: nil)
    }

    static func decodeBinaryFrame(_ data: Data) -> BinaryFrame? {
        // Frame type is one byte, unlike the following request/subscription ID varint.
        guard let byte = data.first else { return nil }
        switch UInt64(byte) {
        case LuxoBinaryProtocol.callSuccess, LuxoBinaryProtocol.callError, LuxoBinaryProtocol.stream,
            LuxoBinaryProtocol.subscribeSuccess, LuxoBinaryProtocol.subscribeError:
            break
        default:
            return nil
        }
        var decoder = Decoder(data)
        let type = decoder.readVarint()
        let id = decoder.readVarint()
        guard decoder.error == nil else { return nil }
        return BinaryFrame(type: type, id: id, payload: decoder.readRemainingData())
    }

    static func subscriptionAcknowledgement(_ frame: BinaryFrame) -> SubscriptionAcknowledgement? {
        guard frame.type == LuxoBinaryProtocol.subscribeSuccess || frame.type == LuxoBinaryProtocol.subscribeError
        else {
            return nil
        }
        if frame.type == LuxoBinaryProtocol.subscribeSuccess && !frame.payload.isEmpty { return nil }
        let error =
            frame.type == LuxoBinaryProtocol.subscribeError
            ? LuxoBinaryProtocol.decodeError(frame.payload, statusCode: 0)
            : nil
        return SubscriptionAcknowledgement(id: frame.id, error: error)
    }

}
