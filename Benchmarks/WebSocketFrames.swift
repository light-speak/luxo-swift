import Foundation

enum WebSocketFrameBenchmark {
    static func run() throws {
        let ids: [UInt64] = [1, 253, 65_535, 9_007_199_254_740_993, UInt64(Int64.max)]
        let record: LuxoValue = .object([
            "id": .int(Int64.min), "name": .string("precision"), "optional": .null,
            "bytes": .bytes(Data([1, 2, 3])), "ratio": .float(1.25),
        ])
        let fixtures: [(String, [String: LuxoValue]?)] = [
            ("no parameters", nil),
            ("one signed integer", ["id": .int(Int64.max)]),
            ("16 nested records", ["input": .array(Array(repeating: record, count: 16))]),
        ]
        for (name, params) in fixtures {
            for id in ids {
                let previous = try previousJSONFrame(sequence: id, params: params)
                let current = try LuxoWebSocketProtocol.jsonCallFrame(sequence: id, api: "check", params: params)
                precondition(previous == current, "JSON wire bytes changed")
            }
            try TransportMetadataBenchmark.compare(
                "JSON WebSocket frame: \(name)", iterations: 2_000, warmup: 200,
                before: { index in
                    UInt64(try previousJSONFrame(sequence: ids[index % ids.count], params: params).count)
                },
                after: { index in
                    UInt64(
                        try LuxoWebSocketProtocol.jsonCallFrame(
                            sequence: ids[index % ids.count], api: "check", params: params
                        ).count
                    )
                }
            )
        }
    }

    // Frozen old sender: valid only through Int64.max. Both paths use the same serializer.
    private static func previousJSONFrame(sequence: UInt64, params: [String: LuxoValue]?) throws -> Data {
        var body = params ?? [:]
        body["$id"] = .int(Int64(sequence))
        body["$api"] = .string("check")
        return try JSONSerialization.data(
            withJSONObject: previousFoundation(.object(body)), options: [.fragmentsAllowed, .sortedKeys]
        )
    }

    // Keep the old conversion here too, so the new Float finiteness check is measured.
    private static func previousFoundation(_ value: LuxoValue) throws -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .float(let value): return value
        case .jsonNumber:
            throw LuxoError(code: 0, message: "raw JSON numbers are outside the frozen fixture", name: "BenchmarkError")
        case .string(let value): return value
        case .bytes(let value): return value.base64EncodedString()
        case .array(let values): return try values.map { try previousFoundation($0) }
        case .object(let values): return try values.mapValues { try previousFoundation($0) }
        case .structured(let value): return try previousFoundation(value.luxoJSONValue())
        }
    }
}
