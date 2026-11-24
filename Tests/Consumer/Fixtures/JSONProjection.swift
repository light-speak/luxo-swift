import Foundation
import LuxoClient
#if LUXO_CODABLE_ALLOCATION
    import Darwin
#endif

func verifyJSONProjection() async throws {
    try await verifyHandwrittenJSONDepth()
    try verifyHandwrittenOverwrittenValues()
    try verifyHandwrittenDiscardedJSONBounds()
    try verifyHandwrittenNestedReplayBounds()
    for record in ["{}", #"{"unknown":1}"#] {
        for items in [
            "[\(record)]", "[\(record),{\"id\":1}]", "[{\"id\":1},\(record)]",
            "[{\"id\":1},\(record),{\"id\":2}]",
        ] {
            try await rejectJSONProjection(items, read: { try await $0.listRecords(select: "id") })
            try await rejectJSONProjection(
                "{\"items\":\(items),\"total\":2,\"page\":1,\"pageSize\":2}",
                read: { try await $0.listRecordPage(select: "id") })
            try await rejectProjectionStream(items)
        }
        try await rejectJSONProjection(
            "{\"id\":1,\"profiles\":[\(record)]}", read: { try await $0.getRecord(select: "profiles { name }") })
        try await rejectJSONProjection(
            "[{\"id\":1,\"profiles\":[\(record)]}]", read: { try await $0.listRecords(select: "profiles { name }") })
    }
    try verifyGeneratedJSONDepth()
    try await verifyGeneratedModelWriteDepth()
    try await verifyGeneratedHTTPJSONDepth()
    try verifyProjectionExceptions()
    try verifyProjectionNamesAndEmptySchema()
    let empty = try await projectionClient("[]").listRecords(select: "id")
    guard empty.isEmpty else { throw projectionFailure("empty list changed") }
    print("Generated JSON model/type lists reject empty projections; null, generic JSON and empty lists preserved")
}

private final class HandwrittenDepthNode: Decodable, Sendable {
    let metadata: JSONValue?
    let child: HandwrittenDepthNode?
    let children: [HandwrittenDepthNode]?
}

private func handwrittenReadText(_ layers: Int, lists: Bool, json: Int = 0, objects: Bool = false) -> String {
    let open = objects ? "{\"v\":" : "["
    let close = objects ? "}" : "]"
    var text =
        "{\"metadata\":" + String(repeating: open, count: json) + "7" + String(repeating: close, count: json) + "}"
    for _ in 1..<layers { text = lists ? "{\"children\":[\(text)]}" : "{\"child\":\(text)}" }
    return text
}

func benchmarkHandwrittenReads() throws {
    let decoder = LuxoJSONDecoder()
    var samples = [false, true].flatMap { lists in [1, 16, 32].map { ("\(lists)/\($0)", $0, lists, 0, false) } }
    samples += [("jsonArray125", 1, false, 125, false), ("jsonObject125", 1, false, 125, true)]
    for (name, layers, lists, json, objects) in samples {
        let text = handwrittenReadText(layers, lists: lists, json: json, objects: objects)
        let data = Data(text.utf8)
        var leaf = try decoder.decode(HandwrittenDepthNode.self, from: data)
        for _ in 1..<layers {
            guard let child = lists ? leaf.children?.first : leaf.child else {
                throw projectionFailure("benchmark lost node")
            }
            leaf = child
        }
        var expected = JSONValue.integer(7)
        for _ in 0..<json { expected = objects ? .object(["v": expected]) : .array([expected]) }
        guard leaf.metadata == expected else { throw projectionFailure("benchmark changed JSON value") }
        try measureHandwrittenRead("codableRead/\(name)") {
            handwrittenChecksum(try decoder.decode(HandwrittenDepthNode.self, from: data))
        }
    }
    let model = handwrittenReadText(16, lists: false)
    let array = Data("[\(model)]".utf8), dictionary = Data("{\"root\":\(model)}".utf8)
    try measureHandwrittenRead("codableRead/rootArray16") {
        UInt64(try decoder.decode([HandwrittenDepthNode].self, from: array).count)
    }
    try measureHandwrittenRead("codableRead/rootDictionary16") {
        UInt64(try decoder.decode([String: HandwrittenDepthNode].self, from: dictionary).count)
    }
    try measureHandwrittenRead("codableRead/primitive") { UInt64(try decoder.decode(Int.self, from: Data("7".utf8))) }
    let integers = Data(("[" + Array(repeating: "7", count: 32).joined(separator: ",") + "]").utf8)
    try measureHandwrittenRead("codableRead/intList32") { UInt64(try decoder.decode([Int].self, from: integers).count) }
}

func benchmarkHandwrittenContextReads() throws {
    let decoder = LuxoJSONDecoder()
    let json = String(repeating: "{\"v\":", count: 65) + "7" + String(repeating: "}", count: 65)
    let item = "{\"number\":7,\"metadata\":\(json)}"
    func data(_ old: String, _ last: String) -> Data {
        Data("{\"metadata\":\(json),\"value\":\(old),\"value\":\(last)}".utf8)
    }
    let model = data("{}", item), list = data("[{},{}]", "[\(item)]")
    let dictionary = data("{\"x\":{},\"y\":{}}", "{\"x\":\(item)}"), optional = data("{}", "null")
    let reference = try decoder.decode(OverwrittenHandwrittenRoot<OverwrittenHandwrittenModel>.self, from: model)
    let expected = try JSONValue.parse(Data(json.utf8))
    guard reference.metadata == expected, reference.value.metadata == expected else {
        throw projectionFailure("context benchmark changed generic JSON")
    }
    let samples: [(String, UInt64, () throws -> UInt64)] = [
        (
            "duplicateModel", 7,
            {
                UInt64(
                    try decoder.decode(OverwrittenHandwrittenRoot<OverwrittenHandwrittenModel>.self, from: model).value
                        .number)
            }
        ),
        (
            "duplicateList", 1,
            {
                UInt64(
                    try decoder.decode(OverwrittenHandwrittenRoot<[OverwrittenHandwrittenModel]>.self, from: list).value
                        .count)
            }
        ),
        (
            "duplicateDictionary", 1,
            {
                UInt64(
                    try decoder.decode(
                        OverwrittenHandwrittenRoot<[String: OverwrittenHandwrittenModel]>.self,
                        from: dictionary
                    ).value.count)
            }
        ),
        (
            "duplicateOptionalNull", 1,
            {
                try decoder.decode(OverwrittenHandwrittenOptionalRoot.self, from: optional).value == nil ? 1 : 0
            }
        ),
    ]
    for (name, expected, operation) in samples {
        guard try operation() == expected else { throw projectionFailure("context benchmark changed last value") }
        try measureHandwrittenRead("codableContext/\(name)", operation: operation)
    }
    try benchmarkHandwrittenJSONFailureRecovery(decoder, reference: model)
}

private func benchmarkHandwrittenJSONFailureRecovery(_ decoder: LuxoJSONDecoder, reference: Data) throws {
    let json129 = String(repeating: "[", count: 129) + "7" + String(repeating: "]", count: 129)
    let inputs = [
        ("json129Recovery", Data("{\"metadata\":\(json129),\"value\":null}".utf8)),
        ("duplicateRequiredJSON129Recovery", Data("{\"metadata\":\(json129),\"metadata\":7,\"value\":null}".utf8)),
        (
            "discardedJSON129Recovery",
            Data("{\"metadata\":7,\"value\":{\"number\":7,\"metadata\":\(json129)},\"value\":null}".utf8)
        ),
    ]
    for (name, input) in inputs {
        try measureHandwrittenRead("codableContext/\(name)") {
            let failed = try rejectedHandwritten(
                OverwrittenHandwrittenOptionalRoot.self, input: input,
                decoder: decoder, name: "ParseError")
            let recovered = try decoder.decode(
                OverwrittenHandwrittenRoot<OverwrittenHandwrittenModel>.self,
                from: reference
            ).value.number
            guard recovered == 7 else { throw projectionFailure("context benchmark did not recover") }
            return failed + UInt64(recovered)
        }
    }
    let bytes = Data("{\"metadata\":7,\"data\":\(json129),\"data\":\"AQ==\"}".utf8)
    try measureHandwrittenRead("codableContext/duplicateDataJSON129Recovery") {
        let failed = try rejectedHandwritten(
            OverwrittenHandwrittenBytesRoot.self,
            input: bytes, decoder: decoder, name: "ParseError")
        let recovered = try decoder.decode(
            OverwrittenHandwrittenRoot<OverwrittenHandwrittenModel>.self,
            from: reference
        ).value.number
        guard recovered == 7 else { throw projectionFailure("data benchmark did not recover") }
        return failed + UInt64(recovered)
    }
}

func benchmarkNewHandwrittenDepthReads() throws {
    let decoder = LuxoJSONDecoder()
    for lists in [false, true] {
        let input = Data(handwrittenReadText(64, lists: lists, json: 128).utf8)
        var leaf = try decoder.decode(HandwrittenDepthNode.self, from: input)
        for _ in 1..<64 {
            guard let child = lists ? leaf.children?.first : leaf.child else {
                throw projectionFailure("new depth benchmark lost model")
            }
            leaf = child
        }
        var expected = JSONValue.integer(7)
        for _ in 0..<128 { expected = .array([expected]) }
        guard leaf.metadata == expected else { throw projectionFailure("new depth benchmark changed JSON") }
        try measureHandwrittenRead("codableNew/\(lists ? "lists64JSON128" : "models64JSON128")") {
            handwrittenChecksum(try decoder.decode(HandwrittenDepthNode.self, from: input))
        }
    }
    let json = String(repeating: "{\"v\":", count: 65) + "7" + String(repeating: "}", count: 65)
    let model = handwrittenReadText(64, lists: false)
    let input = Data("{\"metadata\":\(json),\"value\":[],\"value\":[\(model)]}".utf8)
    try measureHandwrittenRead("codableNew/retainedModel65Recovery") {
        let failed = try rejectedHandwritten(
            OverwrittenHandwrittenRoot<[HandwrittenDepthNode]>.self,
            input: input, decoder: decoder, name: "DecodingError")
        let recovered = try decoder.decode(HandwrittenDepthNode.self, from: Data("{\"metadata\":7}".utf8))
        return failed + handwrittenChecksum(recovered)
    }
}

private func rejectedHandwritten<Value: Decodable>(
    _ type: Value.Type, input: Data, decoder: LuxoJSONDecoder, name: String
) throws -> UInt64 {
    do { _ = try decoder.decode(type, from: input) } catch let error as LuxoError where error.name == name { return 1 }
    throw projectionFailure("context benchmark accepted invalid depth")
}

@inline(never)
private func handwrittenChecksum(_ node: HandwrittenDepthNode) -> UInt64 { node.metadata == nil ? 1 : 2 }

@inline(never)
private func measureHandwrittenRead(_ name: String, operation: () throws -> UInt64) rethrows {
    if let sample = CommandLine.arguments.first(where: { $0.hasPrefix("--sample=") }),
        name != String(sample.dropFirst(9))
    {
        return
    }
    var checksum: UInt64 = 0
    #if LUXO_CODABLE_ALLOCATION
        for _ in 0..<100 { checksum &+= try operation() }
        for _ in 0..<10 {
            checksum &+= try codableAllocationIteration(operation)
            let block = codableAllocationCalibration()
            free(block)
        }
        print("READY iterations=10 checksum=\(checksum)")
        fflush(stdout)
        _ = readLine()
    #else
        for _ in 0..<600 { checksum &+= try operation() }
        for batch in 0..<12 {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<100 { checksum &+= try operation() }
            print("\(name)\t\(batch)\t\(Double(DispatchTime.now().uptimeNanoseconds - start) / 100)\t\(checksum)")
        }
    #endif
}

#if LUXO_CODABLE_ALLOCATION
    @inline(never)
    private func codableAllocationIteration(_ operation: () throws -> UInt64) rethrows -> UInt64 {
        try operation() &+ 1
    }

    @inline(never)
    private func codableAllocationCalibration() -> UnsafeMutableRawPointer { malloc(12345)! }
#endif

private func verifyHandwrittenJSONDepth() async throws {
    let json = String(repeating: "[", count: 128) + "9223372036854775808" + String(repeating: "]", count: 128)
    let expected = try JSONValue.parse(Data(json.utf8))
    for lists in [false, true] {
        for layers in [63, 64, 65] {
            var text = "{\"metadata\":\(json)}"
            for _ in 1..<layers { text = lists ? "{\"children\":[\(text)]}" : "{\"child\":\(text)}" }
            let transport = HTTPTransport(backend: ProjectionHTTPBackend(body: Data("{\"data\":\(text)}".utf8)))
            let payload = try await transport.call("handwritten")
            guard payload.data == Data(text.utf8) else { throw projectionFailure("handwritten body changed") }
            do {
                var node = try LuxoJSONDecoder().decode(HandwrittenDepthNode.self, from: payload.data)
                if layers == 65 { throw projectionFailure("handwritten model65 accepted") }
                for _ in 1..<layers {
                    guard let child = lists ? node.children?.first : node.child else {
                        throw projectionFailure("lost handwritten node")
                    }
                    node = child
                }
                guard node.metadata == expected else { throw projectionFailure("handwritten numeric JSON changed") }
            } catch let error as LuxoError
                where layers == 65 && error.name == "DecodingError" && error.message.contains("64")
            {
            }
        }
    }
    print("Public handwritten Codable and raw HTTP accept model64/JSON128 without Schema and reject model65")
}

private struct OverwrittenHandwrittenModel: Decodable { let number: Int; let metadata: JSONValue }
private struct OverwrittenHandwrittenRoot<Value: Decodable>: Decodable { let metadata: JSONValue; let value: Value }
private struct OverwrittenHandwrittenOptionalRoot: Decodable {
    let metadata: JSONValue
    let value: OverwrittenHandwrittenModel?
}
private struct OverwrittenHandwrittenJSONRoot: Decodable { let metadata: JSONValue }
private struct OverwrittenHandwrittenBytesRoot: Decodable { let metadata: JSONValue; let data: Data }

private func verifyHandwrittenDiscardedJSONBounds() throws {
    let decoder = LuxoJSONDecoder()
    for depth in [128, 129] {
        let json = String(repeating: "[", count: depth) + "7" + String(repeating: "]", count: depth)
        let metadata = Data("{\"metadata\":\(json),\"metadata\":7}".utf8)
        let bytes = Data("{\"metadata\":7,\"data\":\(json),\"data\":\"AQ==\"}".utf8)
        if depth == 128 {
            guard try decoder.decode(OverwrittenHandwrittenJSONRoot.self, from: metadata).metadata == .integer(7),
                try decoder.decode(OverwrittenHandwrittenBytesRoot.self, from: bytes).data == Data([1])
            else { throw projectionFailure("discarded JSON128 changed last value") }
        } else {
            _ = try rejectedHandwritten(
                OverwrittenHandwrittenJSONRoot.self,
                input: metadata, decoder: decoder, name: "ParseError")
            _ = try rejectedHandwritten(
                OverwrittenHandwrittenBytesRoot.self,
                input: bytes, decoder: decoder, name: "ParseError")
        }
    }
}

private func verifyHandwrittenNestedReplayBounds() throws {
    final class Node: Decodable { let child: Node? }
    struct Inner: Decodable { let node: Node? }
    struct Outer: Decodable { let inner: Inner }
    struct Root: Decodable { let metadata: JSONValue; let value: Outer }
    let json = String(repeating: "{\"v\":", count: 65) + "7" + String(repeating: "}", count: 65)
    let decoder = LuxoJSONDecoder()
    for layers in [61, 62, 128, 129] {
        var node = "{}"
        for _ in 1..<layers { node = "{\"child\":\(node)}" }
        for last in ["{}", "{\"node\":null}"] {
            let old = "{\"inner\":{\"node\":\(node)},\"inner\":\(last)}"
            let input = Data("{\"metadata\":\(json),\"value\":\(old),\"value\":{\"inner\":{\"node\":null}}}".utf8)
            if layers <= 128 {
                guard try decoder.decode(Root.self, from: input).value.inner.node == nil else {
                    throw projectionFailure("nested replay changed last value")
                }
            } else {
                _ = try rejectedHandwritten(Root.self, input: input, decoder: decoder, name: "ParseError")
            }
        }
    }
}

private func verifyHandwrittenOverwrittenValues() throws {
    let json = String(repeating: "{\"v\":", count: 65) + "7" + String(repeating: "}", count: 65)
    let item = "{\"number\":7,\"metadata\":\(json)}"
    let decoder = LuxoJSONDecoder()
    func data(_ old: String, _ last: String) -> Data {
        Data("{\"metadata\":\(json),\"value\":\(old),\"value\":\(last)}".utf8)
    }
    for old in ["[{}]", "[{},{}]", "null", "7"] {
        let root = try decoder.decode(
            OverwrittenHandwrittenRoot<[OverwrittenHandwrittenModel]>.self,
            from: data(old, "[\(item)]"))
        guard root.value.count == 1, root.value[0].number == 7 else {
            throw projectionFailure("discarded list changed last value")
        }
    }
    for old in ["{\"x\":{}}", "{\"x\":{},\"y\":{}}", "null", "7"] {
        let root = try decoder.decode(
            OverwrittenHandwrittenRoot<[String: OverwrittenHandwrittenModel]>.self,
            from: data(old, "{\"x\":\(item)}"))
        guard root.value.count == 1, root.value["x"]?.number == 7 else {
            throw projectionFailure("discarded dictionary changed last value")
        }
    }
    for old in ["{}", "null", "7", "[]"] {
        for last in ["null", item] {
            let root = try decoder.decode(OverwrittenHandwrittenOptionalRoot.self, from: data(old, last))
            guard root.value?.number == (last == "null" ? nil : 7) else {
                throw projectionFailure("discarded optional changed last value")
            }
        }
    }
    print("Public handwritten Codable preserves all16 overwritten collection/optional last values without Schema")
}

private func verifyProjectionNamesAndEmptySchema() throws {
    let decoder = LuxoJSONDecoder()
    let named = try decoder.decode([ProjectionNames].self, from: Data(#"[{"container":null}]"#.utf8))
    guard try named[0].container.requireValue() == nil else { throw projectionFailure("generated name collision") }
    _ = try decoder.decode(ProjectionEmpty.self, from: Data("{}".utf8))
    guard try decoder.decode([ProjectionEmpty].self, from: Data("[]".utf8)).isEmpty else {
        throw projectionFailure("empty schema list changed")
    }
    for json in ["[{}]", #"[{"unknown":1}]"#, "[1]", "[null]"] {
        do {
            _ = try decoder.decode([ProjectionEmpty].self, from: Data(json.utf8))
        } catch is DecodingError { continue }
        throw projectionFailure("zero-field schema accepted nonempty list")
    }
}

private func verifyProjectionExceptions() throws {
    let decoder = LuxoJSONDecoder()
    let single = try decoder.decode(Record.self, from: Data("{}".utf8))
    guard case .unselected = single.id else { throw projectionFailure("singleton changed") }
    let dictionary = try decoder.decode([String: Record].self, from: Data(#"{"0":{}}"#.utf8))
    guard dictionary.count == 1 else { throw projectionFailure("numeric object key became a list index") }
    for json in [#"[{"profile":null}]"#, #"[{"profiles":[]}]"#, #"[{"profile":{}}]"#] {
        guard try decoder.decode([Record].self, from: Data(json.utf8)).count == 1 else {
            throw projectionFailure("selected field was rejected")
        }
    }
    let nulls = try decoder.decode([Profile].self, from: Data(#"[{"bio":null}]"#.utf8))
    guard try nulls[0].bio.requireValue() == nil else { throw projectionFailure("selected null changed") }
    let generic = try decoder.decode([JSONValue].self, from: Data(#"[{}, {"unknown":{}}]"#.utf8))
    guard generic.count == 2 else { throw projectionFailure("generic JSON restricted") }
    let inputs = try decoder.decode([ProfileInput].self, from: Data(#"[{"name":"input"}]"#.utf8))
    guard inputs[0].name == "input", inputs[0].bio == nil else { throw projectionFailure("input changed") }
}

private func rejectJSONProjection<Value>(
    _ json: String, read: (LuxoGeneratedClient) async throws -> Value
) async throws {
    do {
        _ = try await read(projectionClient(json))
    } catch let error as LuxoError where error.name == "DecodeError" {
        return
    }
    throw projectionFailure("empty/unknown-only model list accepted: \(json)")
}

private func rejectProjectionStream(_ json: String) async throws {
    let values = ScalarReceiver<[Record]>()
    let errors = ScalarReceiver<LuxoError>()
    let cancel = try await projectionClient(json).subscribeWatchRecords(
        select: "id", observer: StreamObserver(onError: { errors.append($0) }), handler: { values.append($0) })
    cancel()
    guard values.values.isEmpty, errors.values.count == 1, errors.values[0].name == "DecodeError" else {
        throw projectionFailure("bad list did not fail stream decoding exactly once")
    }
}

private func projectionClient(_ json: String) throws -> LuxoGeneratedClient {
    try LuxoGeneratedClient(transport: ProjectionTransport(data: Data(json.utf8)))
}

private func projectionFailure(_ message: String) -> LuxoError {
    LuxoError(code: 0, message: message, name: "ConsumerError")
}

private struct ProjectionTransport: ConsumerTransport {
    let data: Data
    func call(_ api: String, params: [String: LuxoValue]?) async throws -> TransportPayload {
        TransportPayload(data: data, mode: .json)
    }
    func subscribe<Value: Sendable>(
        _ api: String, decoder: @escaping @Sendable (TransportPayload) throws -> Value,
        params: [String: LuxoValue]?, observer: StreamObserver?, handler: @escaping @Sendable (Value) -> Void
    ) async throws -> (@Sendable () -> Void) {
        deliverConsumerPayload(
            TransportPayload(data: data, mode: .json), decoder: decoder, observer: observer, handler: handler)
        return {}
    }
    func setToken(_ token: String) {}
    func setMode(_ mode: TransportMode) {}
    func setSchema(_ schema: [String: APISchema]) {}
}

private func verifyGeneratedJSONDepth() throws {
    let decoder = LuxoJSONDecoder()
    let json = String(repeating: "[", count: 128) + "null" + String(repeating: "]", count: 128)
    let leaf = "{\"metadata\":\(json),\"documents\":[\(json)]}"
    _ = try decoder.decode(DepthNode.self, from: Data(leaf.utf8))
    _ = try decoder.decode(DepthNodeInput.self, from: Data(leaf.utf8))
    _ = try decoder.decode([DepthNode].self, from: Data("[\(leaf)]".utf8))
    _ = try decoder.decode(
        Page<DepthNode>.self, from: Data("{\"items\":[\(leaf)],\"total\":1,\"page\":1,\"pageSize\":1}".utf8))
    _ = try decoder.decode(Cursor<DepthNode>.self, from: Data("{\"items\":[\(leaf)],\"hasMore\":false}".utf8))
    for (open, close) in [("{\"child\":", "}"), ("{\"children\":[", "]}")] {
        let valid = String(repeating: open, count: 63) + leaf + String(repeating: close, count: 63)
        _ = try decoder.decode(DepthNode.self, from: Data(valid.utf8))
        _ = try decoder.decode([DepthNodeInput].self, from: Data("[\(valid)]".utf8))
        try rejectGeneratedDepth(open + valid + close)
        try rejectGeneratedDepth("{\"child\":\(open + valid + close),\"child\":null}")
    }
    for pair in ["\"metadata\":[\(json)],\"metadata\":null", "\"metadata\":null,\"metadata\":[\(json)]"] {
        try rejectGeneratedDepth("{\(pair)}")
    }
    print(
        "Generated model/list/page JSON roots accept 128 containers; model roots accept 64 objects; discarded duplicates remain checked"
    )
}

private func rejectGeneratedDepth(_ json: String) throws {
    do {
        _ = try LuxoJSONDecoder().decode(DepthNode.self, from: Data(json.utf8))
    } catch { return }
    throw projectionFailure("generated model accepted excessive depth")
}

private func verifyGeneratedHTTPJSONDepth() async throws {
    let json = String(repeating: "[", count: 128) + "null" + String(repeating: "]", count: 128)
    let payload = "{\"metadata\":\(json),\"documents\":[\(json)]}"
    let backend = ProjectionHTTPBackend(body: Data("{\"data\":\(payload)}".utf8))
    let client = try LuxoGeneratedClient(transport: HTTPTransport(backend: backend))
    _ = try await client.getDepthNode(select: "metadata,documents")
    print("Generated HTTP client preserves independent JSON128 inside response models and typed JSON lists")
}

private struct ProjectionHTTPBackend: HTTPBackend {
    let body: Data
    func send(body: Data, mode: TransportMode, headers: [String: String]) async throws -> HTTPBackendResponse {
        HTTPBackendResponse(status: 200, body: self.body)
    }
}

private func writeDepthJSON(_ layers: Int) -> JSONValue {
    var value = JSONValue.string("leaf")
    for _ in 0..<layers { value = .array([value]) }
    return value
}

private func writeDepthInput(_ layers: Int, lists: Bool, json: Int) -> DepthNodeInput {
    let value = writeDepthJSON(json)
    var node = DepthNodeInput(metadata: value, documents: [value], children: [], depth: "leaf")
    for _ in 1..<layers {
        node = lists ? DepthNodeInput(children: [node]) : DepthNodeInput(child: node)
    }
    return node
}

private func writeDepthOutput(_ layers: Int, lists: Bool, json: Int) -> DepthNode {
    let value = writeDepthJSON(json)
    var node = DepthNode(
        metadata: .value(value), documents: .value([value]), children: .value([]), depth: .value("leaf"))
    for _ in 1..<layers {
        node = lists ? DepthNode(children: .value([node])) : DepthNode(child: .value(node))
    }
    return node
}

private func checkModelWrite(
    _ label: String, limit: Int?, failures: inout [String], run: () throws -> Void
) {
    do {
        try run()
        if let limit { failures.append("\(label): accepted above \(limit)") }
    } catch {
        guard let limit, let failure = error as? LuxoError,
            ["ConfigError", "EncodingError"].contains(failure.name),
            failure.message.contains("\(limit)")
        else { failures.append("\(label): unexpected \(error)"); return }
    }
}

private func verifyGeneratedModelWriteDepth() async throws {
    var failures: [String] = []
    for lists in [false, true] {
        for layers in [1, 63, 64, 65] {
            let input = writeDepthInput(layers, lists: lists, json: 128)
            let output = writeDepthOutput(layers, lists: lists, json: 128)
            let limit: Int? = layers > 64 ? 64 : nil
            let expected = limit == nil ? try writeDepthJSONBytes(layers, lists: lists, json: 128) : nil
            let label = "model\(layers),lists=\(lists)"
            checkModelWrite("Binary \(label)", limit: limit, failures: &failures) {
                var encoder = Encoder()
                try input.writeLuxo(to: &encoder)
                if expected != nil {
                    var decoder = Decoder(encoder.data)
                    try verifyWrittenDepthInput(&decoder, layers: layers, lists: lists, json: writeDepthJSON(128))
                    guard decoder.isAtEnd, decoder.error == nil else {
                        throw projectionFailure("Binary write trailing data")
                    }
                }
            }
            checkModelWrite("input Codable \(label)", limit: limit, failures: &failures) {
                let data = try LuxoJSONEncoder().encode(input)
                if let expected, data != expected { throw projectionFailure("input model JSON changed") }
            }
            checkModelWrite("output Codable \(label)", limit: limit, failures: &failures) {
                let data = try LuxoJSONEncoder().encode(output)
                if let expected, data != expected { throw projectionFailure("output model JSON changed") }
            }
            try await checkGeneratedWriteRequest(
                input, limit: limit, label: label, expected: expected, failures: &failures)
            try await checkUnregisteredWriteRequest(
                input, limit: limit, label: label, expected: expected, failures: &failures)
        }
    }
    for lists in [false, true] {
        let input = writeDepthInput(64, lists: lists, json: 129)
        checkModelWrite("Binary JSON129", limit: 128, failures: &failures) {
            var encoder = Encoder()
            try input.writeLuxo(to: &encoder)
        }
        checkModelWrite("Codable JSON129", limit: 128, failures: &failures) {
            _ = try LuxoJSONEncoder().encode(input)
        }
        try await checkGeneratedWriteRequest(input, limit: 128, label: "JSON129", failures: &failures)
    }
    guard failures.isEmpty else { throw projectionFailure(failures.joined(separator: "\n")) }
    print("Generated JSON/Binary writes preserve model64 and independent JSON128; invalid requests never send")
}

private func checkGeneratedWriteRequest(
    _ input: DepthNodeInput, limit: Int?, label: String, expected: Data? = nil, failures: inout [String]
) async throws {
    for mode in [TransportMode.json, .binary] {
        let backend = WriteDepthBackend(expected: expected, includesList: true)
        let transport = HTTPTransport(backend: backend)
        transport.setMode(mode)
        let client = try LuxoGeneratedClient(transport: transport)
        do {
            guard try await client.echoDepthNode(value: input, values: [input]) else {
                throw projectionFailure("false write response")
            }
            if limit != nil { failures.append("request \(mode),\(label): accepted") }
        } catch {
            if let limit, let error = error as? LuxoError,
                ["ConfigError", "EncodingError"].contains(error.name), error.message.contains("\(limit)")
            {
            } else {
                failures.append("request \(mode),\(label): unexpected \(error)")
            }
        }
        let sent = await backend.count
        if sent != (limit == nil ? 1 : 0) { failures.append("request \(mode),\(label): sent \(sent)") }
    }
}

private actor WriteDepthBackend: HTTPBackend {
    private(set) var count = 0
    let expected: Data?
    let includesList: Bool
    init(expected: Data?, includesList: Bool) {
        self.expected = expected
        self.includesList = includesList
    }
    func send(body: Data, mode: TransportMode, headers: [String: String]) async throws -> HTTPBackendResponse {
        count += 1
        if mode == .json, let expected {
            var reference = Data("{\"$api\":\"echoDepthNode\",\"value\":".utf8)
            reference.append(expected)
            if includesList {
                reference.append(Data(",\"values\":[".utf8))
                reference.append(expected)
                reference.append(93)
            }
            reference.append(125)
            guard body == reference else { throw projectionFailure("request model JSON changed") }
        }
        return HTTPBackendResponse(
            status: 200, body: mode == .json ? Data("{\"data\":true}".utf8) : Data([1]))
    }
}

private func checkUnregisteredWriteRequest(
    _ input: DepthNodeInput, limit: Int?, label: String, expected: Data? = nil, failures: inout [String]
) async throws {
    let backend = WriteDepthBackend(expected: expected, includesList: false)
    let transport = HTTPTransport(backend: backend)
    do {
        let payload = try await transport.call("echoDepthNode", params: ["value": .structured(input)])
        guard try LuxoJSONDecoder().decode(Bool.self, from: payload.data) else {
            throw projectionFailure("false unregistered response")
        }
        if limit != nil { failures.append("unregistered JSON,\(label): accepted") }
    } catch {
        if let limit, let error = error as? LuxoError,
            ["ConfigError", "EncodingError"].contains(error.name), error.message.contains("\(limit)")
        {
        } else {
            failures.append("unregistered JSON,\(label): unexpected \(error)")
        }
    }
    let sent = await backend.count
    if sent != (limit == nil ? 1 : 0) { failures.append("unregistered JSON,\(label): sent \(sent)") }
}

private func writeDepthJSONBytes(_ layers: Int, lists: Bool, json: Int) throws -> Data {
    let raw = String(decoding: try writeDepthJSON(json).jsonData(), as: UTF8.self)
    var text = "{\"children\":[],\"depth\":\"leaf\",\"documents\":[\(raw)],\"metadata\":\(raw)}"
    for _ in 1..<layers { text = lists ? "{\"children\":[\(text)]}" : "{\"child\":\(text)}" }
    return Data(text.utf8)
}

private func verifyWrittenDepthInput(
    _ decoder: inout Decoder, layers: Int, lists: Bool, json: JSONValue
) throws {
    let leaf = layers == 1
    guard decoder.readVarint() == (leaf ? 4 : 0), decoder.nextField() == 1 else {
        throw projectionFailure("Binary input arena or field order changed")
    }
    let metadata = try decoder.readNullable { try JSONValue.parseBinary($0.readBytes()) }
    guard metadata == (leaf ? json : nil), decoder.nextField() == 2 else {
        throw projectionFailure("Binary input JSON root changed")
    }
    let documents = try decoder.readNullable { d in try d.readArray { try JSONValue.parseBinary($0.readBytes()) } }
    guard documents == (leaf ? [json] : nil), decoder.nextField() == 3 else {
        throw projectionFailure("Binary input JSON list changed")
    }
    let child = decoder.readBool()
    guard child == (!lists && !leaf) else { throw projectionFailure("Binary input child flag changed") }
    if child { try verifyWrittenDepthInput(&decoder, layers: layers - 1, lists: lists, json: json) }
    guard decoder.nextField() == 4 else { throw projectionFailure("Binary input children field changed") }
    let children = decoder.readBool()
    guard children == (lists || leaf) else { throw projectionFailure("Binary input list flag changed") }
    if children {
        guard decoder.readVarint() == (leaf ? 0 : 1) else { throw projectionFailure("Binary input list count changed") }
        if !leaf { try verifyWrittenDepthInput(&decoder, layers: layers - 1, lists: lists, json: json) }
    }
    guard decoder.nextField() == 5, decoder.readStringPtr() == (leaf ? "leaf" : nil), decoder.nextField() == 0 else {
        throw projectionFailure("Binary input depth field or end marker changed")
    }
}
