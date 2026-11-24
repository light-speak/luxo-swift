import Foundation

/// Compares valid error decoding; fixtures and output checks run outside timing.
enum ErrorResponseBenchmark {
    static func run() throws {
        for detailed in [false, true] {
            let json = try [400, 401, 403, 404, 422, 500].map { code -> [String: Any] in
                let optional =
                    detailed ? #", "traceId":"trace", "cause":"cause", "data":{"id":9223372036854775807}"# : ""
                let text = "{\"error\":\"RemoteError\",\"code\":\(code),\"message\":\"failed\"\(optional)}"
                return try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
            }
            let binary = json.map { value -> Data in
                var encoder = Encoder()
                encoder.writeVarint(1)
                encoder.writeSvarint(Int64(value["code"] as! Int))
                encoder.writeVarint(2)
                encoder.writeString("RemoteError")
                encoder.writeVarint(3)
                encoder.writeString("failed")
                if detailed {
                    encoder.writeVarint(4)
                    encoder.writeString("trace")
                    encoder.writeVarint(5)
                    encoder.writeBytes(Data(#"{"id":9223372036854775807}"#.utf8))
                    encoder.writeVarint(6)
                    encoder.writeString("cause")
                }
                encoder.writeEnd()
                return encoder.data
            }
            let detail = detailed ? "full" : "minimal"
            try compare(
                "JSON \(detail) error", count: json.count,
                before: { previousJSON(json[$0]) },
                after: { LuxoError.fromResponse(json: json[$0], statusCode: 502) })
            try compare(
                "Binary \(detail) error", count: binary.count,
                before: { previousBinary(binary[$0], statusCode: 502) },
                after: { LuxoBinaryProtocol.decodeError(binary[$0], statusCode: 502) })
        }
    }

    private static func compare(
        _ name: String, count: Int, before: (Int) -> LuxoError, after: (Int) -> LuxoError
    ) throws {
        for index in 0..<count {
            let old = before(index)
            let new = after(index)
            precondition(old.code == new.code && old.name == new.name && old.message == new.message)
            precondition(old.traceId == new.traceId && old.cause == new.cause)
            let oldData = try JSONSerialization.data(
                withJSONObject: old.data ?? NSNull(), options: [.fragmentsAllowed, .sortedKeys])
            let newData = try JSONSerialization.data(
                withJSONObject: new.data ?? NSNull(), options: [.fragmentsAllowed, .sortedKeys])
            precondition(oldData == newData)
        }
        TransportMetadataBenchmark.compare(
            name,
            before: { checksum(before($0 % count)) },
            after: { checksum(after($0 % count)) })
    }

    private static func checksum(_ error: LuxoError) -> UInt64 {
        UInt64(error.code + error.name.utf8.count + error.message.utf8.count + (error.traceId?.utf8.count ?? 0))
    }

    // Frozen pre-fix code, intentionally retaining its missing-field defaults and unchecked cast.
    private static func previousJSON(_ json: [String: Any]) -> LuxoError {
        LuxoError(
            code: json["code"] as? Int ?? 0,
            message: json["message"] as? String ?? "Unknown error",
            name: json["name"] as? String ?? json["error"] as? String ?? "Error",
            traceId: json["traceId"] as? String,
            data: json["data"],
            cause: json["cause"] as? String
        )
    }

    // Frozen pre-fix valid path; never used by SDK runtime or conformance tests.
    private static func previousBinary(_ data: Data, statusCode: Int) -> LuxoError {
        var decoder = Decoder(data)
        var code = statusCode
        var name = "Error"
        var message = "HTTP \(statusCode)"
        var traceId: String?
        var errorData: Any?
        var cause: String?
        var seen = 0
        var ended = false
        while decoder.remaining > 0 {
            let fieldID = decoder.nextField()
            if fieldID == 0 {
                ended = decoder.error == nil
                break
            }
            switch fieldID {
            case 1:
                code = Int(decoder.readSvarint())
                seen |= 1
            case 2:
                name = decoder.readString()
                seen |= 2
            case 3:
                message = decoder.readString()
                seen |= 4
            case 4: traceId = decoder.readString()
            case 5:
                do {
                    errorData = try JSONSerialization.jsonObject(
                        with: decoder.readBytes(), options: [.fragmentsAllowed])
                } catch {
                    return previousParseError(statusCode, "invalid JSON data")
                }
            case 6: cause = decoder.readString()
            default: return previousParseError(statusCode, "unknown binary error field \(fieldID)")
            }
        }
        if let error = decoder.error { return previousParseError(statusCode, error) }
        if !ended { return previousParseError(statusCode, "missing end marker") }
        if decoder.remaining != 0 { return previousParseError(statusCode, "trailing bytes") }
        if seen != 7 { return previousParseError(statusCode, "missing required fields") }
        return LuxoError(code: code, message: message, name: name, traceId: traceId, data: errorData, cause: cause)
    }

    private static func previousParseError(_ statusCode: Int, _ message: String) -> LuxoError {
        LuxoError(code: statusCode, message: "invalid binary error response: \(message)", name: "ParseError")
    }
}
