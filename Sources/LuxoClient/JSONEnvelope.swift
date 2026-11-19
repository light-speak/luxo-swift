import Foundation

/// Validated transport metadata plus the untouched JSON payload, not a second object tree.
struct JSONEnvelope {
    let fields: [String: LuxoValue]
    // Capture control-key presence during parsing, avoiding a second hash lookup per frame.
    let hasTerminalMetadata: Bool
    let discardedPayload: Bool
    private let source: Data
    private let payload: Range<Int>?

    var hasData: Bool { payload != nil }

    var responseData: Data? {
        guard let payload else { return nil }
        // Data slices can have a nonzero startIndex; reader offsets are always relative.
        return source[(source.startIndex + payload.lowerBound)..<(source.startIndex + payload.upperBound)]
    }

    static func decode(
        _ data: Data, errorResponse: Bool = false, schema: LuxoJSONReadSchema? = nil, untypedSuccess: Bool = false
    ) throws -> JSONEnvelope {
        try decode(
            data, errorResponse: errorResponse, schema: schema, untypedSuccess: untypedSuccess, resolvesPayload: false,
            resolvePayload: { _ in .generic })
    }

    static func decode(
        _ data: Data, errorResponse: Bool = false, schema: LuxoJSONReadSchema? = nil,
        resolvePayload: ([String: LuxoValue]) -> JSONPayloadValidation
    ) throws -> JSONEnvelope {
        try decode(
            data, errorResponse: errorResponse, schema: schema, untypedSuccess: false, resolvesPayload: true,
            resolvePayload: resolvePayload)
    }

    // Keep the synchronous route callback nonescaping so every WS frame can use stack captures.
    private static func decode(
        _ data: Data, errorResponse: Bool, schema: LuxoJSONReadSchema?, untypedSuccess: Bool, resolvesPayload: Bool,
        resolvePayload: ([String: LuxoValue]) -> JSONPayloadValidation
    ) throws -> JSONEnvelope {
        try data.withUnsafeBytes { raw in
            var reader = JSONReader(bytes: raw.bindMemory(to: UInt8.self))
            if reader.bytes.starts(with: [0xef, 0xbb, 0xbf]) { reader.offset = 3 }
            let parsed = try reader.envelope(
                errorResponse: errorResponse, schema: schema, untypedSuccess: untypedSuccess,
                resolvesPayload: resolvesPayload,
                resolvePayload: resolvePayload)
            reader.whitespace()
            guard reader.offset == raw.count else { throw reader.invalid() }
            var discarded = false
            do {
                if resolvesPayload {
                    if parsed.fields["error"] == nil, !errorResponse,
                        parsed.payloadRouteVersion == parsed.routeVersion, let policy = parsed.payloadPolicy
                    {
                        if let failure = parsed.payloadFailure { throw failure }
                        discarded = policy.isDiscarded
                    } else {
                        let policy: JSONPayloadValidation =
                            errorResponse || parsed.fields["error"] != nil ? .generic : resolvePayload(parsed.fields)
                        try reader.validatePayloads(parsed, policy: policy)
                        discarded = policy.isDiscarded
                    }
                } else if !errorResponse, schema != nil || untypedSuccess, parsed.fields["error"] != nil {
                    // A late error key changes every data value, including overwritten duplicates, to generic JSON.
                    try reader.validatePayloads(parsed, policy: .generic)
                } else if let failure = parsed.payloadFailure {
                    throw failure
                }
            } catch is JSONModelDepthFailure {
                // Model depth is a typed payload error. Malformed JSON still retires the connection.
                try reader.validatePayloads(parsed, policy: .discarded)
                throw JSONEnvelopePayloadFailure(fields: parsed.fields)
            }
            return JSONEnvelope(
                fields: parsed.fields, hasTerminalMetadata: parsed.terminal,
                discardedPayload: discarded, source: data, payload: parsed.payload)
        }
    }

    func materializedFields() throws -> [String: LuxoValue] {
        var values = fields
        if let data = responseData, values["data"] == nil { values["data"] = try JSONReader.decode(data) }
        return values
    }

    static func decodeError(_ envelope: JSONEnvelope, statusCode: Int) -> LuxoError {
        do {
            return LuxoError.fromResponse(values: try envelope.materializedFields(), statusCode: statusCode)
        } catch {
            // Error data uses the generic JSON budget even when the envelope was read as a typed success.
            return LuxoError(code: statusCode, message: "invalid JSON error response", name: "ParseError")
        }
    }
}

struct JSONEnvelopePayloadFailure: Error {
    let fields: [String: LuxoValue]
}

enum JSONPayloadValidation {
    case generic
    case schema(LuxoJSONReadSchema)
    // Successful raw bytes receive semantic budgets in their eventual typed reader.
    case untyped
    // Unknown or already retired WS operations have no typed payload consumer.
    case discarded

    var isDiscarded: Bool { if case .discarded = self { return true }; return false }
}

private struct ParsedJSONEnvelope {
    var fields: [String: LuxoValue] = [:]
    var payload: Range<Int>?
    var firstPayload: Range<Int>?
    var previousPayloads: [Range<Int>] = []
    var payloadFailure: Error?
    var terminal = false
    var routeVersion = 0
    var payloadRouteVersion: Int?
    var payloadPolicy: JSONPayloadValidation?
}

private struct JSONDiscardFrame {
    let closing: UInt8
    var count: UInt32 = 0

    mutating func recordValue() {
        // Arrays stop at one million items; objects only need a nonempty marker.
        count = closing == 125 ? 1 : count + 1
    }
}

// The common nesting range stays on the stack; deeper retired payloads spill without recursive calls.
private struct JSONDiscardStack {
    let inline: UnsafeMutableBufferPointer<JSONDiscardFrame>
    private var overflow: [JSONDiscardFrame] = []
    private var count = 0

    init(inline: UnsafeMutableBufferPointer<JSONDiscardFrame>) { self.inline = inline }

    var last: JSONDiscardFrame? {
        guard count != 0 else { return nil }
        return count <= inline.count ? inline[count - 1] : overflow[count - inline.count - 1]
    }

    mutating func append(_ frame: JSONDiscardFrame) {
        if count < inline.count { inline[count] = frame } else { overflow.append(frame) }
        count += 1
    }

    mutating func removeLast() {
        if count > inline.count { overflow.removeLast() }
        count -= 1
    }

    mutating func incrementLast() {
        if count <= inline.count {
            inline[count - 1].recordValue()
        } else {
            overflow[count - inline.count - 1].recordValue()
        }
    }
}

extension JSONReader {
    fileprivate mutating func envelope(
        errorResponse: Bool, schema: LuxoJSONReadSchema?, untypedSuccess: Bool, resolvesPayload: Bool,
        resolvePayload: ([String: LuxoValue]) -> JSONPayloadValidation
    ) throws -> ParsedJSONEnvelope {
        whitespace()
        guard take(123) else { throw invalid() }
        var parsed = ParsedJSONEnvelope()
        whitespace()
        if take(125) { return parsed }
        var complete: Bool
        repeat {
            whitespace()
            let key = try string()
            whitespace()
            guard take(58) else { throw invalid() }
            whitespace()
            switch key {
            case "data":
                try envelopeData(
                    &parsed, errorResponse: errorResponse, schema: schema, untypedSuccess: untypedSuccess,
                    resolvesPayload: resolvesPayload,
                    resolvePayload: resolvePayload)
            case "$end":
                parsed.terminal = true
                parsed.routeVersion += 1
                parsed.fields[key] = try value(depth: 1)
            case "$id", "$sub", "$stream", "error":
                parsed.routeVersion += 1
                parsed.fields[key] = try value(depth: 1)
            case "ok", "code", "message", "traceId", "cause":
                parsed.fields[key] = try value(depth: 1)
            default:
                try skipValue(depth: 1)
            }
            whitespace()
            complete = take(125)
            if !complete, !take(44) { throw invalid() }
        } while !complete
        return parsed
    }

    private mutating func envelopeData(
        _ parsed: inout ParsedJSONEnvelope, errorResponse: Bool, schema: LuxoJSONReadSchema?, untypedSuccess: Bool,
        resolvesPayload: Bool,
        resolvePayload: ([String: LuxoValue]) -> JSONPayloadValidation
    ) throws {
        let start = offset
        if errorResponse || parsed.fields["error"] != nil {
            parsed.fields["data"] = try value(depth: 0)
        } else if resolvesPayload {
            if parsed.payload == nil, parsed.routeVersion != 0 {
                parsed.payloadPolicy = resolvePayload(parsed.fields)
                parsed.payloadRouteVersion = parsed.routeVersion
            }
            if let policy = parsed.payloadPolicy, parsed.payloadRouteVersion == parsed.routeVersion {
                try provisionalPayload(policy, failure: &parsed.payloadFailure)
            } else {
                try skipPayloadBoundary()
            }
        } else if let schema {
            try provisionalPayload(.schema(schema), failure: &parsed.payloadFailure)
        } else if untypedSuccess {
            try skipUntypedValue()
        } else {
            try skipValue(depth: 0)
        }
        if let previous = parsed.payload, resolvesPayload || schema != nil || untypedSuccess {
            if parsed.firstPayload == nil {
                parsed.firstPayload = previous
            } else {
                parsed.previousPayloads.append(previous)
            }
        }
        parsed.payload = start..<offset
    }

    private mutating func provisionalPayload(_ policy: JSONPayloadValidation, failure: inout Error?) throws {
        if case .untyped = policy { try skipUntypedValue(); return }
        let start = offset
        do { try skipPayload(policy) } catch {
            // A later route or error key may change the semantic budget, but never the JSON grammar.
            if failure == nil { failure = error }
            offset = start
            try skipPayloadBoundary()
        }
    }

    private mutating func skipPayload(_ policy: JSONPayloadValidation) throws {
        switch policy {
        case .generic: try skipValue(depth: 0)
        case .schema(let schema): try skipValue(schema: schema)
        case .untyped: try skipUntypedValue()
        case .discarded: try skipDiscardedValue()
        }
    }

    fileprivate func validatePayloads(_ parsed: ParsedJSONEnvelope, policy: JSONPayloadValidation) throws {
        if let range = parsed.firstPayload { try validatePayload(range, policy: policy) }
        for range in parsed.previousPayloads { try validatePayload(range, policy: policy) }
        if let range = parsed.payload { try validatePayload(range, policy: policy) }
    }

    private func validatePayload(_ range: Range<Int>, policy: JSONPayloadValidation) throws {
        var reader = JSONReader(bytes: UnsafeBufferPointer(rebasing: bytes[range]))
        // Captured ranges end at exactly one token or balanced root container.
        // Successful grammar validation consumes that root; outer separators and EOF are checked by envelope().
        try reader.skipPayload(policy)
    }

    // Find the immutable source slice without recursive descent or a temporary value tree.
    // Every captured slice must subsequently pass its final payload policy, including full grammar validation.
    private mutating func skipPayloadBoundary() throws {
        if current == 34 { try skipPayloadStringBoundary(); return }
        guard current == 91 || current == 123 else { try skipValue(depth: 0); return }
        var depth = 0
        while offset < bytes.count {
            switch current {
            case 34: try skipPayloadStringBoundary(); continue
            case 91, 123: depth += 1
            case 93, 125:
                depth -= 1
                if depth == 0 { offset += 1; return }
            default: break
            }
            offset += 1
        }
        throw invalid()
    }

    private mutating func skipPayloadStringBoundary() throws {
        offset += 1
        while offset < bytes.count {
            advanceStringSegment()
            if take(34) { return }
            // Only a physical backslash can escape a quote. The final policy validates escapes and UTF-8.
            guard take(92), offset < bytes.count else { throw invalid() }
            offset += 1
        }
        throw invalid()
    }

    // Untyped and retired payloads have no model description at this boundary.
    // Validate syntax iteratively; a later typed reader applies semantic budgets to delivered bytes.
    private mutating func skipUntypedValue() throws {
        let start = offset
        do { try skipValue(depth: 0) } catch {
            offset = start
            try skipDiscardedValue()
        }
    }

    private mutating func skipDiscardedValue() throws {
        whitespace()
        guard current == 91 || current == 123 else { try skipValue(depth: 0); return }
        try withUnsafeTemporaryAllocation(of: JSONDiscardFrame.self, capacity: 128) { inline in
            inline.initialize(repeating: JSONDiscardFrame(closing: 0))
            defer { inline.deinitialize() }
            var frames = JSONDiscardStack(inline: inline)
            try skipDiscardedContainers(&frames)
        }
    }

    private mutating func skipDiscardedContainers(_ frames: inout JSONDiscardStack) throws {
        try startDiscardedValue(&frames)
        while let frame = frames.last {
            whitespace()
            if take(frame.closing) { frames.removeLast(); continue }
            if frame.count != 0 {
                guard take(44) else { throw invalid() }
                whitespace()
            }
            if frame.closing == 125 {
                try skipString()
                whitespace()
                guard take(58) else { throw invalid() }
            } else if frame.count >= 1_000_000 {
                throw invalid()
            }
            frames.incrementLast()
            try startDiscardedValue(&frames)
        }
    }

    private mutating func startDiscardedValue(_ frames: inout JSONDiscardStack) throws {
        whitespace()
        switch current {
        case 91: offset += 1; frames.append(JSONDiscardFrame(closing: 93))
        case 123: offset += 1; frames.append(JSONDiscardFrame(closing: 125))
        default: try skipValue(depth: 0)
        }
    }

    mutating func skipValue(depth: Int) throws {
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
        guard depth < 128 else { throw invalid() }
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
        guard depth < 128 else { throw invalid() }
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
