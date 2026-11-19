import Foundation
#if LUXO_JSON_ALLOCATION
    import Darwin
#endif

/// Compile with the current runtime or an exact source snapshot; compare independent processes.
@main
struct JSONDepthBenchmark {
    static func main() async throws {
        if CommandLine.arguments.contains("--model-writes") { try modelWrites(); return }
        if CommandLine.arguments.contains("--encoder-layout") {
            print("JSONTreeEncoder stride=\(MemoryLayout<JSONTreeEncoder>.stride)")
            print("JSONEncodingNode.Storage stride=\(MemoryLayout<JSONEncodingNode.Storage>.stride)")
            return
        }
        #if LUXO_JSON_TRANSPORT_BENCHMARK
            if CommandLine.arguments.contains("--streams") { try await streams(); return }
            #if !LUXO_JSON_ALLOCATION
                if CommandLine.arguments.contains("--calls") { try await calls(); return }
            #endif
        #endif
        if CommandLine.arguments.contains("--envelopes") { try envelopes(); return }
        if CommandLine.arguments.contains("--read") { try reads(); return }
        if CommandLine.arguments.contains("--boundaries") { try boundaries(); return }
        let samples = [
            ("scalar", "1e400"), ("small", "{\"v\":1}"),
            ("objects128", "[" + Array(repeating: "{\"v\":1}", count: 128).joined(separator: ",") + "]"),
            ("unicode72k", "\"" + String(repeating: "文", count: 24000) + "\""),
            ("depth128", String(repeating: "[", count: 128) + "0" + String(repeating: "]", count: 128)),
            ("empty128", String(repeating: "[", count: 128) + String(repeating: "]", count: 128)),
        ]
        for (name, text) in samples {
            let data = Data(text.utf8)
            let value = try JSONValue.parseBinary(data)
            let envelope = Data(("{\"data\":" + text + "}").utf8)
            let error = Data(("{\"error\":\"Rejected\",\"code\":400,\"message\":\"no\",\"data\":" + text + "}").utf8)
            let iterations = name == "unicode72k" ? 100 : 500
            try measure("parse/\(name)", iterations: iterations) { consume(try JSONValue.parseBinary(data)) }
            try measure("write/\(name)", iterations: iterations) { UInt64(try value.jsonData().count) }
            try measure("project/\(name)", iterations: iterations) { consume(try JSONValue(LuxoValue.encode(value))) }
            try measure("envelope/\(name)", iterations: iterations) {
                UInt64(try JSONEnvelope.decode(envelope).responseData!.count)
            }
            try measure("error/\(name)", iterations: iterations) {
                UInt64(
                    JSONEnvelope.decodeError(try JSONEnvelope.decode(error, errorResponse: true), statusCode: 502).code)
            }
            try measure("binaryWrite/\(name)", iterations: iterations) {
                var encoder = Encoder()
                try encoder.writeJSON(value)
                return UInt64(encoder.data.count)
            }
        }
    }

    private final class WriteNode: Encodable, Sendable {
        let metadata: JSONValue?
        let child: WriteNode?
        let children: [WriteNode]?
        init(metadata: JSONValue? = nil, child: WriteNode? = nil, children: [WriteNode]? = nil) {
            self.metadata = metadata
            self.child = child
            self.children = children
        }
    }

    private static func modelWrites() throws {
        let encoder = LuxoJSONEncoder()
        for lists in [false, true] {
            for layers in [1, 16, 32] {
                var node = WriteNode(metadata: .integer(7))
                var expected = "{\"metadata\":7}"
                for _ in 1..<layers {
                    node = lists ? WriteNode(children: [node]) : WriteNode(child: node)
                    expected = lists ? "{\"children\":[\(expected)]}" : "{\"child\":\(expected)}"
                }
                let reference = Data(expected.utf8)
                guard try encoder.encode(node) == reference else {
                    throw LuxoError(code: 0, message: "model write bytes differ", name: "BenchmarkError")
                }
                try measure("modelWrite/\(lists ? "lists" : "scalar")/\(layers)", iterations: 300) {
                    UInt64(try encoder.encode(node).count)
                }
            }
        }
        let value = ["root": [WriteNode(metadata: .integer(7))]]
        guard try encoder.encode(value) == Data("{\"root\":[{\"metadata\":7}]}".utf8) else {
            throw LuxoError(code: 0, message: "collection write bytes differ", name: "BenchmarkError")
        }
        try measure("modelWrite/dictionaryList/1", iterations: 500) { UInt64(try encoder.encode(value).count) }
        try measure("modelWrite/primitive/1", iterations: 1000) { UInt64(try encoder.encode(7).count) }
    }

    #if LUXO_JSON_TRANSPORT_BENCHMARK
        private static func responseSchema() -> APISchema {
            #if LUXO_JSON_ENVELOPE_SCHEMA
                return APISchema(
                    id: 7, response: .model("Packet", types: ["Packet": ["value": .init(fieldID: 1, type: "JSON")]]))
            #else
                return APISchema(id: 7)
            #endif
        }

        private static func streams() async throws {
            let samples = [
                ("small", "{\"v\":true}"),
                ("objects128", "[" + Array(repeating: "{\"v\":true}", count: 128).joined(separator: ",") + "]"),
                ("unicode72k", "\"" + String(repeating: "文", count: 24000) + "\""),
                ("depth125", String(repeating: "[", count: 125) + "null" + String(repeating: "]", count: 125)),
            ]
            for (name, text) in samples {
                for first in [true, false] {
                    let socket = BenchmarkSocket(legacy: false)
                    let transport = try WebSocketTransport(
                        url: "ws://localhost/bench", session: BenchmarkSession(socket))
                    try transport.setSchema(["watch": responseSchema()])
                    transport.connect()
                    let stop = try await transport.subscribe("watch", decoder: { UInt64($0.data.count) }) { _ in
                        socket.record()
                    }
                    let packet = "\"data\":{\"value\":\(text)}"
                    let frame = URLSessionWebSocketTask.Message.string(
                        first ? "{\"$stream\":1,\(packet)}" : "{\(packet),\"$stream\":1}")
                    measure(
                        "stream/\(first ? "routeFirst" : "dataFirst")/\(name)",
                        iterations: name == "unicode72k" ? 100 : 500
                    ) {
                        socket.deliver(frame)
                        return 1
                    }
                    stop(); transport.close()
                }
            }
        }

        #if !LUXO_JSON_ALLOCATION
            private struct FixedHTTPBackend: HTTPBackend {
                let response: Data
                func send(body: Data, mode: TransportMode, headers: [String: String]) async throws
                    -> HTTPBackendResponse
                {
                    HTTPBackendResponse(status: 200, body: response)
                }
            }

            private static func calls() async throws {
                for (name, value) in [
                    ("small", "{\"v\":true}"),
                    ("objects128", "[" + Array(repeating: "{\"v\":true}", count: 128).joined(separator: ",") + "]"),
                ] {
                    let response = Data("{\"data\":{\"value\":\(value)}}".utf8)
                    let transport = HTTPTransport(backend: FixedHTTPBackend(response: response))
                    try transport.setSchema(["read": responseSchema()])
                    try await measureAsync("call/http/\(name)") { UInt64(try await transport.call("read").data.count) }
                }
                let socket = BenchmarkSocket(legacy: false)
                let transport = try WebSocketTransport(url: "ws://localhost/bench", session: BenchmarkSession(socket))
                #if LUXO_JSON_ENVELOPE_SCHEMA
                    try transport.setSchema(["read": APISchema(id: 7, response: .json)])
                #else
                    try transport.setSchema(["read": APISchema(id: 7)])
                #endif
                transport.connect()
                try await measureAsync("call/ws/scalar") { UInt64(try await transport.call("read").data.count) }
                transport.close()
            }

            @inline(never)
            private static func measureAsync(_ name: String, operation: () async throws -> UInt64) async rethrows {
                var sink: UInt64 = 0
                for _ in 0..<600 { sink &+= try await operation() }
                for batch in 0..<12 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    for _ in 0..<100 { sink &+= try await operation() }
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 100
                    print("\(name)\t\(batch)\t\(elapsed)\t\(sink)")
                }
            }
        #endif
    #endif

    private static func envelopes() throws {
        let samples = [
            ("small", "{\"v\":true}"),
            ("objects128", "[" + Array(repeating: "{\"v\":true}", count: 128).joined(separator: ",") + "]"),
            ("unicode72k", "\"" + String(repeating: "文", count: 24000) + "\""),
            ("depth125", String(repeating: "[", count: 125) + "null" + String(repeating: "]", count: 125)),
        ]
        let model = LuxoJSONReadSchema.model("Packet", types: ["Packet": ["value": .init(fieldID: 1, type: "JSON")]])
        for (name, text) in samples {
            let packet = "{\"value\":\(text)}"
            let cases = [
                ("plain", "{\"data\":\(text)}"), ("model", "{\"data\":\(packet)}"),
                ("list", "{\"data\":[\(text)]}"),
                ("wsFirst", "{\"$id\":1,\"data\":\(packet)}"),
                ("wsLate", "{\"data\":\(packet),\"$id\":1}"),
                ("errorLate", "{\"data\":\(packet),\"error\":\"Rejected\",\"code\":400,\"message\":\"no\"}"),
                ("duplicate", "{\"data\":\(packet),\"data\":\(packet)}"),
                ("discarded", "{\"$id\":1,\"data\":\(packet)}"),
            ]
            for (kind, document) in cases {
                let data = Data(document.utf8)
                let schema = kind == "list" ? LuxoJSONReadSchema.list(.json) : model
                try measure("envelope/\(kind)/\(name)", iterations: name == "unicode72k" ? 100 : 500) {
                    #if LUXO_JSON_ENVELOPE_SCHEMA
                        let envelope: JSONEnvelope
                        switch kind {
                        case "plain": envelope = try JSONEnvelope.decode(data)
                        case "wsFirst", "wsLate":
                            envelope = try JSONEnvelope.decode(data, resolvePayload: { _ in .schema(schema) })
                        case "discarded": envelope = try JSONEnvelope.decode(data, resolvePayload: { _ in .discarded })
                        default: envelope = try JSONEnvelope.decode(data, schema: schema)
                        }
                    #else
                        _ = schema
                        let envelope = try JSONEnvelope.decode(data)
                    #endif
                    if kind == "errorLate" { return UInt64(JSONEnvelope.decodeError(envelope, statusCode: 400).code) }
                    return UInt64(envelope.responseData!.count)
                }
            }
        }
    }

    fileprivate struct ReadPacket: Decodable, Sendable { let value: JSONValue }

    private static func reads() throws {
        let samples = [
            ("small", "{\"v\":true}"),
            ("objects128", "[" + Array(repeating: "{\"v\":true}", count: 128).joined(separator: ",") + "]"),
            ("unicode72k", "\"" + String(repeating: "文", count: 24000) + "\""),
            ("depth125", String(repeating: "[", count: 125) + "null" + String(repeating: "]", count: 125)),
        ]
        let decoder = LuxoJSONDecoder()
        for (name, text) in samples {
            let data = Data(text.utf8)
            let list = Data("[\(text)]".utf8)
            let packet = Data("{\"value\":\(text)}".utf8)
            let page = Data("{\"items\":[\(text)],\"total\":1,\"page\":1,\"pageSize\":1}".utf8)
            let iterations = name == "unicode72k" ? 100 : 500
            try measure("jsonRead/\(name)", iterations: iterations) {
                consume(try decoder.decode(JSONValue.self, from: data))
            }
            try measure("listRead/\(name)", iterations: iterations) {
                consume(try decoder.decode([JSONValue].self, from: list)[0])
            }
            try measure("modelRead/\(name)", iterations: iterations) {
                consume(try decoder.decode(ReadPacket.self, from: packet).value)
            }
            try measure("pageRead/\(name)", iterations: iterations) {
                consume(try decoder.decode(Page<JSONValue>.self, from: page).items[0])
            }
        }
        let data = Data("123".utf8)
        try measure("scalarRead/int", iterations: 500) { UInt64(try decoder.decode(Int.self, from: data)) }
        let invalid = Data(
            ("[" + String(repeating: "[", count: 129) + "null" + String(repeating: "]", count: 129) + "]").utf8)
        try measure("invalidRead/depth129", iterations: 500) {
            do { _ = try decoder.decode([JSONValue].self, from: invalid) } catch { return 1 }
            throw LuxoError(code: 0, message: "deep JSON accepted", name: "BenchmarkError")
        }
    }

    private struct Packet: Encodable, Sendable { let value: JSONValue }

    private static func boundaries() throws {
        let samples = [
            ("small", "{\"v\":true}"),
            ("objects128", "[" + Array(repeating: "{\"v\":true}", count: 128).joined(separator: ",") + "]"),
            ("unicode72k", "\"" + String(repeating: "文", count: 24000) + "\""),
            ("depth64", String(repeating: "[", count: 64) + "null" + String(repeating: "]", count: 64)),
            ("depth125", String(repeating: "[", count: 125) + "null" + String(repeating: "]", count: 125)),
            ("depth128", String(repeating: "[", count: 128) + "null" + String(repeating: "]", count: 128)),
        ]
        let schema = APISchema(id: 1, params: [.init(fieldID: 1, name: "value", type: "JSON")])
        for (name, text) in samples {
            let data = Data(text.utf8)
            let value = try JSONValue.parseBinary(data)
            let raw = LuxoValue(value)
            let iterations = name == "unicode72k" ? 100 : 500
            try measure("foundationRead/\(name)", iterations: iterations) {
                consume(try JSONDecoder().decode(JSONValue.self, from: data))
            }
            try measure("foundationWrite/\(name)", iterations: iterations) {
                UInt64(try JSONEncoder().encode(value).count)
            }
            try measure("write/\(name)", iterations: iterations) { UInt64(try value.jsonData().count) }
            try measure("project/\(name)", iterations: iterations) { consume(try JSONValue(LuxoValue.encode(value))) }
            try measure("binaryWrite/\(name)", iterations: iterations) {
                var encoder = Encoder()
                try encoder.writeJSON(value)
                return UInt64(encoder.data.count)
            }
            if CommandLine.arguments.contains("--direct") {
                try measure("binaryRequestWrite/\(name)", iterations: iterations) {
                    UInt64(try LuxoBinaryProtocol.encodeRequest(schema: schema, params: ["value": raw]).count)
                }
            }
            // The previous writer cannot represent a depth-128 root below a model or list.
            // Functional tests cover those newly accepted values without a non-equivalent cost comparison.
            if name == "depth128" { continue }
            try measure("modelWrite/\(name)", iterations: iterations) {
                UInt64(try LuxoJSONEncoder().encode(Packet(value: value)).count)
            }
            try measure("listWrite/\(name)", iterations: iterations) {
                UInt64(try LuxoJSONEncoder().encode([value]).count)
            }
            try measure("requestWrite/\(name)", iterations: iterations) {
                UInt64(
                    try LuxoJSONRequest.encode(
                        api: "echo", params: ["value": .checkedJSON(value)], plan: schema.jsonParameters
                    ).count)
            }
            try measure("rawRequestWrite/\(name)", iterations: iterations) {
                UInt64(
                    try LuxoJSONRequest.encode(api: "echo", params: ["value": raw], plan: schema.jsonParameters).count)
            }
        }
        if CommandLine.arguments.contains("--direct") { try requestControls() }
        measure("jsonSchemaInit/single", iterations: 500) {
            consumeSchema(APISchema(id: 1, params: [.init(fieldID: 1, name: "value", type: "JSON")]))
        }
    }

    private static func requestControls() throws {
        let cases: [(String, APISchema, LuxoValue)] = [
            ("integer", APISchema(id: 1, params: [.init(fieldID: 1, name: "value", type: "Int")]), .int(Int64.max)),
            (
                "dateTime", APISchema(id: 1, params: [.init(fieldID: 1, name: "value", type: "DateTime")]),
                .string("2000-01-01T00:00:00.123456789Z")
            ),
            (
                "model128",
                APISchema(
                    id: 1, params: [.init(fieldID: 1, name: "value", type: "Model", typeName: "Item", isList: true)],
                    types: ["Item": ["id": .init(fieldID: 1, type: "Int")]]),
                .array((0..<128).map { .object(["id": .int(Int64($0))]) })
            ),
            ("opaque128", APISchema(id: 1), .array((0..<128).map { .object(["id": .int(Int64($0))]) })),
        ]
        for (name, schema, value) in cases {
            try measure("controlRequest/\(name)", iterations: 500) {
                UInt64(
                    try LuxoJSONRequest.encode(api: "echo", params: ["value": value], plan: schema.jsonParameters).count
                )
            }
        }
        let schema = APISchema(id: 1, params: [.init(fieldID: 1, name: "value", type: "JSON")])
        var deep: LuxoValue = .null
        for _ in 0..<129 { deep = .array([deep]) }
        for (name, value) in [("depth129", deep), ("bytes", LuxoValue.bytes(Data([1])))] {
            try measure("invalidJSON/\(name)", iterations: 500) {
                do {
                    _ = try LuxoJSONRequest.encode(api: "echo", params: ["value": value], plan: schema.jsonParameters)
                } catch let error as LuxoError where error.name == "EncodingError" || error.name == "DecodingError" {
                    return 1
                }
                throw LuxoError(code: 0, message: "invalid JSON accepted", name: "BenchmarkError")
            }
        }
    }

    #if LUXO_JSON_ALLOCATION
        @inline(never)
        private static func allocationIteration(_ operation: () throws -> UInt64) rethrows -> UInt64 {
            let value = try operation()
            return value &+ 1
        }

        @inline(never)
        private static func allocateCalibrationBlock() -> UnsafeMutableRawPointer { malloc(12345)! }
    #endif

    @inline(never)
    private static func consumeSchema(_ schema: APISchema) -> UInt64 {
        UInt64(schema.params?.count ?? 0) + (schema.jsonParameters == nil ? 0 : 1)
    }

    @inline(never)
    private static func consume(_ value: JSONValue) -> UInt64 {
        switch value {
        case .array(let items): return UInt64(items.count)
        case .object(let items): return UInt64(items.count)
        case .string(let text): return UInt64(text.utf8.count)
        default: return 1
        }
    }

    @inline(never)
    private static func measure(_ name: String, iterations: Int, operation: () throws -> UInt64) rethrows {
        if CommandLine.arguments.contains("--direct")
            && (name.hasPrefix("foundation") || name.hasPrefix("jsonSchema") || name.hasPrefix("project"))
        {
            return
        }
        if CommandLine.arguments.contains("--skip-invalid"), name.hasPrefix("invalidJSON/") { return }
        if let sample = CommandLine.arguments.first(where: { $0.hasPrefix("--sample=") }),
            name != String(sample.dropFirst(9))
        {
            return
        }
        var sink: UInt64 = 0
        #if LUXO_JSON_ALLOCATION
            for _ in 0..<100 { sink &+= try operation() }
            for _ in 0..<10 {
                sink &+= try allocationIteration(operation)
                let block = allocateCalibrationBlock()
                free(block)
            }
            print("READY iterations=10 checksum=\(sink)")
            fflush(stdout)
            _ = readLine()
        #else
            for _ in 0..<6 {
                for _ in 0..<iterations { sink &+= try operation() }
            }
            for batch in 0..<12 {
                let start = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<iterations { sink &+= try operation() }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations)
                print("\(name)\t\(batch)\t\(elapsed)\t\(sink)")
            }
        #endif
    }
}

#if LUXO_JSON_READ_SCHEMA
    extension JSONDepthBenchmark.ReadPacket: LuxoJSONSchemaProviding {
        static let luxoJSONSchema = LuxoJSONReadSchema.model(
            "Packet", types: ["Packet": ["value": .init(fieldID: 1, type: "JSON")]])
    }
#endif
