import Foundation

enum SchemaRegistrationBenchmark {
    static func run() throws {
        for (apis, fields, types) in [(1, 2, 0), (16, 16, 0), (16, 16, 16)] {
            let schema = fixture(apis: apis, fields: fields, types: types)
            let before = RegistrationState()
            let after = RegistrationState()
            try TransportMetadataBenchmark.compare(
                "Schema registration apis=\(apis) fields=\(fields) types=\(types)",
                iterations: types == 0 ? 2_000 : 100, warmup: types == 0 ? 200 : 10,
                before: { _ in
                    before.replace(schema); return before.count()
                },
                after: { _ in
                    try after.validateAndReplace(schema); return after.count()
                })
        }
    }

    private static func fixture(apis: Int, fields: Int, types: Int) -> [String: APISchema] {
        let selections = Dictionary(
            uniqueKeysWithValues: (1...fields).map {
                ("field\($0)", APISchema.SelectionFieldSchema(fieldID: $0, type: "Int"))
            })
        let typeFields = Dictionary(uniqueKeysWithValues: (0..<types).map { ("Type\($0)", selections) })
        return Dictionary(
            uniqueKeysWithValues: (1...apis).map {
                (
                    "api\($0)",
                    APISchema(
                        id: $0, params: [.init(fieldID: 1, name: "value", type: "Int")],
                        fields: selections, types: typeFields)
                )
            })
    }

    /// Both paths retain the same lock/value assignment; only the new path validates IDs.
    private final class RegistrationState {
        private let lock = NSLock()
        private var schema: [String: APISchema] = [:]

        @inline(never) func replace(_ value: [String: APISchema]) {
            lock.withLock { schema = value }
        }

        @inline(never) func validateAndReplace(_ value: [String: APISchema]) throws {
            try validateRuntimeSchemaIDs(value)
            lock.withLock { schema = value }
        }

        @inline(never) func count() -> UInt64 { lock.withLock { UInt64(schema.count) } }
    }
}
