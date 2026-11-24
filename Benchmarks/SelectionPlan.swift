import Foundation

/// Current text encoding versus schema-bound plans; not an old-version or network comparison.
enum SelectionPlanBenchmark {
    private struct Request: GeneratedRequest {
        let apiID = 1
        let selection: String?
        var selectionPlan: PreparedSelection?
        func writeParameters(to encoder: inout Encoder) throws {}
        func toJSONParameters() throws -> [String: LuxoValue] { [:] }
    }

    static func run() throws {
        for count in [0, 2, 16, 64] {
            let fields = Dictionary(
                uniqueKeysWithValues: (0..<count).map {
                    ("field\($0)", APISchema.SelectionFieldSchema(fieldID: $0 + 1, type: "Int"))
                })
            let schema = APISchema(id: 1, fields: fields)
            let text = count == 0 ? nil : (0..<count).map { "field\($0)" }.joined(separator: ",")
            let plain = Request(selection: text)
            let plan = try text.map { try PreparedSelection($0, schema: schema) }
            let prepared = Request(selection: text, selectionPlan: plan)
            let expected = try LuxoBinaryProtocol.encodeRequest(schema: schema, request: plain)
            let actual = try LuxoBinaryProtocol.encodeRequest(schema: schema, request: prepared)
            precondition(expected == actual)
            try TransportMetadataBenchmark.compare("selection warm fields=\(count)", iterations: 10_000, warmup: 1000) {
                _ in
                try checksum(schema, plain)
            } after: { _ in
                try checksum(schema, prepared)
            }
            if let text {
                try TransportMetadataBenchmark.compare(
                    "selection first fields=\(count)", iterations: 10_000, warmup: 1000
                ) { _ in
                    try checksum(schema, plain)
                } after: { _ in
                    let fresh = try PreparedSelection(text, schema: schema)
                    return try checksum(schema, Request(selection: text, selectionPlan: fresh))
                }
            }
        }
        print("Local encoding only; allocations, old-version controls, static initialization and network remain open.")
    }

    @inline(never)
    private static func checksum(_ schema: APISchema, _ request: Request) throws -> UInt64 {
        let data = try LuxoBinaryProtocol.encodeRequest(schema: schema, request: request)
        return UInt64(data.count) ^ UInt64(data.last ?? 0)
    }
}
