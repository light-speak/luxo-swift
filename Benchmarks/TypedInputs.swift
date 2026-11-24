import Foundation

/// Exercises the emitted conversion pattern, excluding generation and network I/O.
enum TypedInputBenchmark {
    struct Input: Codable, LuxoBinaryEncodable {
        let id: Int64
        let ratio: Double
        let name: String
        let note: String?

        func writeLuxo(to encoder: inout Encoder) throws {
            encoder.writeVarint(UInt64(name.utf8.count + (note?.utf8.count ?? 0)))
            encoder.writeVarint(1)
            encoder.writeSvarint(id)
            encoder.writeVarint(2)
            try encoder.writeFixed64(ratio)
            encoder.writeVarint(3)
            encoder.writeString(name)
            encoder.writeVarint(4)
            encoder.writeBool(note != nil)
            if let note { encoder.writeString(note) }
            encoder.writeEnd()
        }

        func luxoJSONValue() throws -> LuxoValue {
            var values = Dictionary<String, LuxoValue>(minimumCapacity: 4)
            values["id"] = LuxoValue(id)
            values["ratio"] = try LuxoValue(finiteFloat: ratio)
            values["name"] = LuxoValue(name)
            if let note { values["note"] = LuxoValue(note) }
            return .object(values)
        }
    }

    static func run() throws {
        let ids: [Int64] = [0, -1, 1, 9_007_199_254_740_993, Int64.min, Int64.max]
        try compareJSON(
            "Integer JSON request preparation",
            before: { index in
                .object(["$api": "echo", "id": try LuxoValue.encode(ids[index % ids.count])])
            },
            after: { index in
                .object(["$api": "echo", "id": LuxoValue(ids[index % ids.count])])
            })
        let inputs = (0..<16).map { index in
            Input(
                id: ids[index % ids.count], ratio: Double(index) + 0.25,
                name: "input-\(index)", note: index.isMultiple(of: 2) ? nil : "present")
        }
        try compareJSON(
            "Structured JSON request preparation",
            before: { index in
                .object(["$api": "echo", "input": try LuxoValue.encode(inputs[index % inputs.count])])
            },
            after: { index in
                .object(["$api": "echo", "input": .structured(inputs[index % inputs.count])])
            })
        try compareJSON(
            "16 structured inputs JSON request preparation",
            before: { _ in
                .object(["$api": "echo", "inputs": try LuxoValue.encode(inputs)])
            },
            after: { _ in
                .object(["$api": "echo", "inputs": .array(inputs.map { .structured($0) })])
            })
    }

    private static func compareJSON(
        _ name: String,
        before: (Int) throws -> LuxoValue,
        after: (Int) throws -> LuxoValue
    ) throws {
        for index in 0..<16 {
            let expected = try before(index).jsonData()
            let actual = try after(index).jsonData()
            precondition(expected == actual)
        }
        try TransportMetadataBenchmark.compare(
            name, iterations: 2_000, warmup: 200,
            before: { index in
                UInt64(try before(index).jsonData().count)
            },
            after: { index in
                UInt64(try after(index).jsonData().count)
            })
    }
}
