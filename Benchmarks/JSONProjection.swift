import Foundation

#if LUXO_PROJECTION_BENCHMARK
    enum JSONProjectionBenchmark {
        static func run() throws {
            for count in [1, 128] {
                for (name, record) in [
                    ("first", #"{"id":7}"#), ("last", #"{"profiles":[]}"#),
                    ("mixed", #"{"id":7,"status":"OPEN","profile":{"name":"user","bio":null},"numbers":[1,2,3]}"#),
                    ("nested", #"{"profiles":[{"name":"user","bio":null}]}"#),
                ] {
                    let json = "[" + Array(repeating: record, count: count).joined(separator: ",") + "]"
                    try compare(
                        "list \(name) \(count)", json: json, count: count,
                        before: [BeforeProjection.Record].self, after: [AfterProjection.Record].self)
                }
            }
            try compare(
                "single", json: #"{"id":7}"#, count: 1,
                before: BeforeProjection.Record.self, after: AfterProjection.Record.self)
            try compare(
                "single empty", json: "{}", count: 1,
                before: BeforeProjection.Record.self, after: AfterProjection.Record.self)
            try compare(
                "empty list", json: "[]", count: 1,
                before: [BeforeProjection.Record].self, after: [AfterProjection.Record].self)
            try compare(
                "page empty", json: #"{"items":[],"total":0,"page":1,"pageSize":10}"#, count: 1,
                before: Page<BeforeProjection.Record>.self, after: Page<AfterProjection.Record>.self)
            let rows = Array(repeating: #"{"id":7}"#, count: 128).joined(separator: ",")
            try compare(
                "page 128", json: "{\"items\":[\(rows)],\"total\":128,\"page\":1,\"pageSize\":128}", count: 128,
                before: Page<BeforeProjection.Record>.self, after: Page<AfterProjection.Record>.self)
            print("Warm generated Decodable only; JSON parsing, allocations, errors, transport and devices unmeasured")
        }

        private static func compare<Before: Decodable, After: Decodable>(
            _ name: String, json: String, count: Int, before: Before.Type, after: After.Type
        ) throws {
            let value = try JSONReader.decode(Data(json.utf8))
            _ = try JSONTreeDecoder(value: value).decode(before)
            _ = try JSONTreeDecoder(value: value).decode(after)
            TransportMetadataBenchmark.compare(
                "projection \(name)", iterations: count == 128 ? 500 : 5_000, warmup: 200,
                before: { _ in
                    let result = try! JSONTreeDecoder(value: value).decode(before)
                    return consume(result)
                },
                after: { _ in
                    let result = try! JSONTreeDecoder(value: value).decode(after)
                    return consume(result)
                })
        }

        @inline(never)
        private static func consume<T>(_ value: T) -> UInt64 {
            withExtendedLifetime(value) { 1 }
        }
    }
#endif
