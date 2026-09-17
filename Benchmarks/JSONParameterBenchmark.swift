import Foundation

/// Keeps request-building improvements separate from the cost of schema validation.
enum JSONParameterBenchmark {
    private struct Reply: Codable, Equatable {
        let id: Int64
        let ratio: Double
        let name: String
    }

    static func runTypedResponses() throws {
        let decoder = JSONDecoder()
        let current = LuxoJSONDecoder()
        let ids = [Int64.min, 0, 1, 9_007_199_254_740_993, Int64.max]
        let scalarData = ids.map { Data(String($0).utf8) }
        for (index, data) in scalarData.enumerated() {
            let old = try decoder.decode(Int64.self, from: data)
            let new = try current.decode(Int64.self, from: data)
            precondition(old == ids[index] && new == ids[index])
        }
        try TransportMetadataBenchmark.compare(
            "typed Int64 response", iterations: 2_000, warmup: 200,
            before: { index in
                UInt64(bitPattern: try decoder.decode(Int64.self, from: scalarData[index % scalarData.count]))
            },
            after: { index in
                UInt64(bitPattern: try current.decode(Int64.self, from: scalarData[index % scalarData.count]))
            })
        let rows = (0..<16).map { Reply(id: ids[$0 % ids.count], ratio: Double($0) + 0.25, name: "東京-\($0)") }
        let data = try JSONEncoder().encode(rows)
        let decoded = try current.decode([Reply].self, from: data)
        precondition(decoded == rows)
        try TransportMetadataBenchmark.compare(
            "typed 16 records response", iterations: 1_000, warmup: 200,
            before: { _ in UInt64(bitPattern: try decoder.decode([Reply].self, from: data)[0].id) },
            after: { _ in UInt64(bitPattern: try current.decode([Reply].self, from: data)[0].id) })
    }

    static func runValues() throws {
        let nested =
            "[" + Array(repeating: "{\"v\":42,\"f\":1.25,\"s\":\"東京\"}", count: 16).joined(separator: ",") + "]"
        for (name, source) in [("integer", "42"), ("fraction", "1.25"), ("string", "\"東京\""), ("16 records", nested)] {
            let data = Data(source.utf8)
            let decoder = JSONDecoder()
            let before = try decoder.decode(LegacyJSONValue.self, from: data)
            let after = try JSONValue.parse(data)
            let normalized = try decoder.decode(LegacyJSONValue.self, from: after.jsonData()).currentValue
            precondition(normalized == before.currentValue)
            try TransportMetadataBenchmark.compare(
                "JSON value: \(name)", iterations: 1000, warmup: 200,
                before: { _ in try decoder.decode(LegacyJSONValue.self, from: data).size },
                after: { _ in size(try JSONValue.parse(data)) })
        }
    }

    private static func size(_ value: JSONValue) -> UInt64 {
        switch value {
        case .array(let values): return UInt64(values.count)
        case .object(let values): return UInt64(values.count)
        default: return 1
        }
    }

    static func run() throws {
        let ids: [Int64] = [0, -1, 1, 9_007_199_254_740_993, Int64.min, Int64.max]
        let scalar = APISchema(id: 1, params: [.init(fieldID: 1, name: "value", type: "Int")])
        try compare("one integer", schema: scalar, params: ids.map { ["value": .int($0)] })
        let inputs = (0..<16).map { index in
            TypedInputBenchmark.Input(
                id: ids[index % ids.count], ratio: Double(index) + 0.25,
                name: "input-\(index)", note: index.isMultiple(of: 2) ? nil : "present")
        }
        let records = APISchema(
            id: 1,
            params: [
                .init(fieldID: 1, name: "value", type: "Model", typeName: "Input", isList: true)
            ],
            types: [
                "Input": [
                    "id": .init(fieldID: 1, type: "Int"), "ratio": .init(fieldID: 2, type: "Float"),
                    "name": .init(fieldID: 3, type: "String"),
                    "note": .init(fieldID: 4, type: "String", nullable: true),
                ]
            ])
        try compare(
            "16 manual records", schema: records,
            params: [["value": .array(try inputs.map { try $0.luxoJSONValue() })]])
        try compare(
            "16 typed records", schema: records,
            params: [["value": .array(inputs.map { .structured($0) })]])
    }

    private static func compare(_ name: String, schema: APISchema, params: [[String: LuxoValue]]) throws {
        for values in params {
            let expected = try previousRequest(values)
            let unchecked = try LuxoJSONRequest.encode(api: "echo", params: values, plan: nil)
            let checked = try LuxoJSONRequest.encode(api: "echo", params: values, plan: schema.jsonParameters)
            precondition(unchecked == expected)
            precondition(checked == expected)
        }
        try TransportMetadataBenchmark.compare(
            "\(name): pre-fix vs integrated validation", iterations: 1_000, warmup: 200,
            before: { index in UInt64(try previousRequest(params[index % params.count]).count) },
            after: { index in
                UInt64(
                    try LuxoJSONRequest.encode(
                        api: "echo", params: params[index % params.count], plan: schema.jsonParameters
                    ).count)
            })
        try TransportMetadataBenchmark.compare(
            "\(name): same builder without vs with validation", iterations: 1_000, warmup: 200,
            before: { index in
                UInt64(try LuxoJSONRequest.encode(api: "echo", params: params[index % params.count], plan: nil).count)
            },
            after: { index in
                UInt64(
                    try LuxoJSONRequest.encode(
                        api: "echo", params: params[index % params.count], plan: schema.jsonParameters
                    ).count)
            })
    }

    // Frozen HTTP request preparation before schema validation, using equivalent valid inputs.
    private static func previousRequest(_ params: [String: LuxoValue]) throws -> Data {
        var body: [String: LuxoValue] = ["$api": .string("echo")]
        for (name, value) in params { body[name] = value }
        return try LuxoValue.object(body).jsonData()
    }
}

// Frozen JSONValue decoder before exact Int64 handling; only exact old inputs are timed.
private enum LegacyJSONValue: Decodable {
    case null, bool(Bool), number(Double), string(String), array([LegacyJSONValue]), object([String: LegacyJSONValue])

    init(from decoder: Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([LegacyJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: LegacyJSONValue].self))
        }
    }

    var size: UInt64 {
        switch self {
        case .array(let values): return UInt64(values.count)
        case .object(let values): return UInt64(values.count)
        default: return 1
        }
    }

    // Normalize the legacy numeric representation only for assertions outside timing.
    var currentValue: JSONValue {
        switch self {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .number(let value): return Int64(exactly: value).map(JSONValue.integer) ?? .number(value)
        case .string(let value): return .string(value)
        case .array(let values): return .array(values.map(\.currentValue))
        case .object(let values): return .object(values.mapValues(\.currentValue))
        }
    }
}
