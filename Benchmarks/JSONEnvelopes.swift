import Foundation

enum JSONEnvelopeBenchmark {
    static func run() throws {
        let precision =
            #"{"id":9223372036854775807,"large":123456789012345678901234567890,"decimal":0.1234567890123456789,"zero":-0,"name":"東京","ok":true,"items":[null,1]}"#
        let list = "[" + Array(repeating: precision, count: 128).joined(separator: ",") + "]"
        let text = "\"" + String(repeating: "東京", count: 12_000) + "\""
        let escaped = "\"" + String(repeating: #"\n\u6771\u4eac"#, count: 128) + "\""
        for (name, payload, iterations) in [
            ("scalar", "7", 50_000), ("object", #"{"id":1,"count":2}"#, 30_000),
            ("precision", precision, 10_000), ("list128", list, 100),
            ("text72KiB", text, 100), ("escaped", escaped, 1_000),
        ] {
            let envelope = Data("{\"$id\":18446744073709551615,\"data\":\(payload)}".utf8)
            let failure = Data("{\"data\":\(payload),\"code\":422,\"error\":\"Rejected\",\"message\":\"failed\"}".utf8)
            let actual = try JSONEnvelope.decode(envelope).responseData
            precondition(actual == Data(payload.utf8))
            try TransportMetadataBenchmark.compare(
                "JSON success \(name)", iterations: iterations, warmup: max(100, iterations / 5),
                before: { _ in UInt64(try previousResponse(envelope).count) },
                after: { _ in UInt64(try JSONEnvelope.decode(envelope).responseData.count) })
            try TransportMetadataBenchmark.compare(
                "HTTP JSON error \(name)", iterations: iterations, warmup: max(100, iterations / 5),
                before: { _ in UInt64(try previousError(failure).code) },
                after: { _ in
                    UInt64(
                        JSONEnvelope.decodeError(try JSONEnvelope.decode(failure, errorResponse: true), statusCode: 500)
                            .code)
                })
            let wsFailure = Data(
                "{\"code\":422,\"error\":\"Rejected\",\"message\":\"failed\",\"data\":\(payload)}".utf8)
            for (order, data) in [("error first", wsFailure), ("data first", failure)] {
                try TransportMetadataBenchmark.compare(
                    "WS JSON error \(name) \(order)", iterations: iterations, warmup: max(100, iterations / 5),
                    before: { _ in UInt64(try previousError(data).code) },
                    after: { _ in UInt64(JSONEnvelope.decodeError(try JSONEnvelope.decode(data), statusCode: 0).code) })
            }
            let data = Data(payload.utf8)
            try TransportMetadataBenchmark.compare(
                "JSON reader \(name)", iterations: iterations, warmup: max(100, iterations / 5),
                before: { _ in try read(LegacyJSONReader.decode(data)) },
                after: { _ in try read(JSONReader.decode(data)) })
        }
        print("Envelope processing only; no network, typed model decoding or allocation measurement.")
    }

    private static func previousResponse(_ data: Data) throws -> Data {
        guard case .object(let values) = try LegacyJSONReader.decode(data) else { preconditionFailure() }
        return try (values["data"] ?? .null).jsonData()
    }

    private static func previousError(_ data: Data) throws -> LuxoError {
        guard case .object(let values) = try LegacyJSONReader.decode(data) else { preconditionFailure() }
        return LuxoError.fromResponse(values: values, statusCode: 500)
    }

    @inline(never)
    private static func read(_ value: LuxoValue) -> UInt64 {
        switch value {
        case .array(let values): return UInt64(values.count)
        case .object(let values): return UInt64(values.count)
        case .string(let value): return UInt64(value.utf8.count)
        case .int(let value): return UInt64(bitPattern: value)
        default: return 1
        }
    }
}
