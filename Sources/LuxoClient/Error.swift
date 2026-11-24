import Foundation

/// Luxo API error with code and message.
/// Supports i18n message keys from server.
public struct LuxoError: LocalizedError, @unchecked Sendable {
    public let code: Int
    public let name: String
    public let message: String
    public let traceId: String?
    public let data: Any?
    public let cause: String?

    public init(
        code: Int,
        message: String,
        name: String = "Error",
        traceId: String? = nil,
        data: Any? = nil,
        cause: String? = nil
    ) {
        self.code = code
        self.message = message
        self.name = name
        self.traceId = traceId
        self.data = data
        self.cause = cause
    }

    public var errorDescription: String? {
        if let traceId = traceId {
            return "[\(name)] \(message) (trace: \(traceId))"
        }
        return "[\(name)] \(message)"
    }

    /// Parse a local error dictionary, retaining defaults for omitted fields.
    /// Present fields must have exact types; transports require a complete envelope.
    public static func from(json: [String: Any]) -> LuxoError {
        decodeJSON(json, statusCode: 0, requireFields: false)
    }

    static func fromResponse(json: [String: Any], statusCode: Int) -> LuxoError {
        decodeJSON(json, statusCode: statusCode, requireFields: true)
    }

    static func fromResponse(values: [String: LuxoValue], statusCode: Int) -> LuxoError {
        do {
            return decodeJSON(
                try values.mapValues { try $0.foundationValue() }, statusCode: statusCode, requireFields: true)
        } catch {
            return LuxoError(code: statusCode, message: "invalid JSON error response", name: "ParseError")
        }
    }

    private static func decodeJSON(
        _ json: [String: Any], statusCode: Int, requireFields: Bool
    ) -> LuxoError {
        let rawCode: Any? = requireFields ? json["code"] : (json["code"] ?? 0)
        let rawName: Any? = requireFields ? json["error"] : (json["name"] ?? json["error"] ?? "Error")
        let rawMessage: Any? = requireFields ? json["message"] : (json["message"] ?? "Unknown error")
        let rawTrace = json["traceId"]
        let rawCause = json["cause"]
        let traceId = rawTrace as? String
        let cause = rawCause as? String
        guard let rawCode, let code = jsonCode(rawCode),
            !requireFields || (400...599).contains(code),
            let name = rawName as? String, let message = rawMessage as? String,
            traceId != nil || isMissingOrNull(rawTrace), cause != nil || isMissingOrNull(rawCause)
        else {
            return LuxoError(code: statusCode, message: "invalid JSON error response", name: "ParseError")
        }
        return LuxoError(
            code: code, message: message, name: name,
            traceId: traceId,
            data: json["data"],
            cause: cause
        )
    }

    private static func jsonCode(_ value: Any) -> Int? {
        if let raw = value as? JSONNumber {
            return raw.isInteger ? Int(raw.literal) : nil
        }
        // Inspect Foundation's numeric storage before accessing a converting property.
        guard let number = (value as AnyObject) as? NSNumber else { return nil }
        switch number.objCType.pointee {
        case 105, 108, 113, 115:  // i, l, q, s
            return Int(exactly: number.int64Value)
        case 73, 76, 81, 83:  // I, L, Q, S
            return Int(exactly: number.uint64Value)
        default:
            return nil
        }
    }

    private static func isMissingOrNull(_ value: Any?) -> Bool {
        value == nil || value is NSNull
    }
}

extension LuxoBinaryProtocol {
    static func decodeError(_ data: Data, statusCode: Int) -> LuxoError {
        var decoder = Decoder(data)
        var fields = BinaryErrorFields()
        var seen = 0
        var ended = false
        while decoder.remaining > 0 {
            let fieldID = decoder.nextField()
            if fieldID == 0 {
                ended = decoder.error == nil
                break
            }
            guard let field = BinaryErrorFields.Field(rawValue: fieldID) else {
                return binaryParseError(statusCode, "unknown binary error field \(fieldID)")
            }
            // Field validates IDs 1...6; use their bit positions directly, leaving bit 0 unused.
            let bit = 1 &<< fieldID
            guard seen & bit == 0 else { return binaryParseError(statusCode, "duplicate field \(fieldID)") }
            seen |= bit
            if let error = fields.read(field, from: &decoder) { return binaryParseError(statusCode, error) }
        }
        if let error = decoder.error { return binaryParseError(statusCode, error) }
        if !ended { return binaryParseError(statusCode, "missing end marker") }
        if decoder.remaining != 0 { return binaryParseError(statusCode, "trailing bytes") }
        if seen & 0b1110 != 0b1110 { return binaryParseError(statusCode, "missing required fields") }
        if !(400...599).contains(fields.code) { return binaryParseError(statusCode, "invalid error status") }
        return fields.finish()
    }

    private static func binaryParseError(_ statusCode: Int, _ message: String) -> LuxoError {
        LuxoError(code: statusCode, message: "invalid binary error response: \(message)", name: "ParseError")
    }
}

private struct BinaryErrorFields {
    enum Field: Int {
        case code = 1, name, message, traceId, data, cause
    }

    var code = 0
    var name = ""
    var message = ""
    var traceId: String?
    var data: Any?
    var cause: String?

    // Transfer the completed fields instead of copying through a borrowed property getter.
    consuming func finish() -> LuxoError {
        LuxoError(code: code, message: message, name: name, traceId: traceId, data: data, cause: cause)
    }

    mutating func read(_ field: Field, from decoder: inout Decoder) -> String? {
        switch field {
        case .code:
            // Supported Swift targets use 64-bit Int; the decoder already checks int64 bounds.
            code = Int(decoder.readSvarint())
        case .name: name = decoder.readString()
        case .message: message = decoder.readString()
        case .traceId: traceId = decoder.readString()
        case .data:
            let bytes = decoder.readBytes()
            if let error = decoder.error { return error }
            do {
                data = try LuxoValue.decodeJSONData(bytes, allowDocumentBOM: false).foundationValue()
            } catch {
                return "invalid JSON data"
            }
        case .cause: cause = decoder.readString()
        }
        return nil
    }
}
