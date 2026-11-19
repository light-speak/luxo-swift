import Foundation
import LuxoClient

func verifyStructuredResponses() async throws {
    let integerBytes = Data(
        [2, 0xff] + Array(repeating: 0xff, count: 8) + [1, 0xfe]
            + Array(repeating: 0xff, count: 8) + [1])
    try await verifyStructured(
        field: 4, payload: integerBytes, json: #"{"numbers":[-9223372036854775808,9223372036854775807]}"#
    ) { record in
        guard try record.numbers.requireValue() == [Int.min, Int.max] else { throw structuredFailure() }
        guard case .unselected = record.profile else { throw structuredFailure() }
    }
    try await verifyStructured(field: 4, payload: Data([0]), json: #"{"numbers":[]}"#) { record in
        guard try record.numbers.requireValue().isEmpty else { throw structuredFailure() }
    }
    let child = Data([4, 1, 4, 76, 117, 120, 111, 2, 0, 0])
    try await verifyStructured(
        field: 3, payload: child, json: #"{"profile":{"name":"Luxo","bio":null}}"#, nullable: true, nested: true
    ) { record in
        guard let profile = try record.profile.requireValue(),
            try profile.name.requireValue() == "Luxo", try profile.bio.requireValue() == nil
        else { throw structuredFailure() }
    }
    try await verifyStructured(field: 3, payload: nil, json: #"{"profile":null}"#, nullable: true, nested: true) {
        guard try $0.profile.requireValue() == nil else { throw structuredFailure() }
    }
    let children = Data([1, 4, 1, 4, 76, 117, 120, 111, 2, 0, 0])
    try await verifyStructured(
        field: 5, payload: children, json: #"{"profiles":[{"name":"Luxo","bio":null}]}"#, nested: true
    ) {
        let profiles = try $0.profiles.requireValue()
        guard profiles.count == 1, try profiles[0].name.requireValue() == "Luxo" else { throw structuredFailure() }
    }
    try await verifyStructured(field: 5, payload: Data([0, 0, 0]), json: #"{"profiles":[]}"#, nested: true) {
        guard try $0.profiles.requireValue().isEmpty else { throw structuredFailure() }
    }
    try await verifyMalformedStructures(child: child, children: children)
    try await verifyRecordPages()
    try await verifyPaginationParameters()
    try await verifyGeneratedBinaryModelDepth()
    try verifyBinaryRequiredModelDepth()
    try await verifyBinaryDepthDiscardedColumns()
    print("Generated row/column/stream nested payloads, Int64 array cells and pagination passed")
}

private func verifyStructured(
    field: UInt8, payload: Data?, json: String, nullable: Bool = false, nested: Bool = false,
    check: (Record) throws -> Void
) async throws {
    let marker = nullable ? Data([payload == nil ? 0 : 1]) : Data()
    let rowValue = payload.map { nested ? structureBlob($0) : $0 } ?? Data()
    let columnValue = payload.map(structureBlob) ?? Data()
    let row = Data([0, field]) + marker + rowValue + Data([0])
    let columns = Data([1, 0, field]) + marker + columnValue + Data([0])
    for binary in [false, true] {
        let rowClient = try structuredClient(binary ? row : Data(json.utf8), binary: binary)
        try check(try await rowClient.getRecord(select: "numbers, profile { name, bio }, profiles { name, bio }"))
        let columnClient = try structuredClient(binary ? columns : Data("[\(json)]".utf8), binary: binary)
        let records = try await columnClient.listRecords(
            select: "numbers, profile { name, bio }, profiles { name, bio }")
        guard records.count == 1 else { throw structuredFailure() }
        try check(records[0])
        try await verifyStructuredStreams(rowClient: rowClient, columnClient: columnClient, check: check)
    }
    try await rejectStructure(row + Data([99]), list: false)
    try await rejectStructure(Data(row.dropLast()), list: false)
    try await rejectStructure(columns + Data([99]), list: true)
    try await rejectStructure(Data(columns.dropLast()), list: true)
}

private func verifyMalformedStructures(child: Data, children: Data) async throws {
    for cell in [Data([1]), Data([0, 99]), Data([1, 0x80])] {
        try await rejectStructure(Data([1, 0, 4]) + structureBlob(cell) + Data([0]), list: true)
    }
    for badChild in [Data(), Data(child.dropLast()), child + Data([99])] {
        try await rejectStructure(Data([0, 3, 1]) + structureBlob(badChild) + Data([0]), list: false)
        try await rejectStructure(Data([1, 0, 3, 1]) + structureBlob(badChild) + Data([0]), list: true)
    }
    for badChildren in [Data(), Data(children.dropLast()), children + Data([99])] {
        try await rejectStructure(Data([0, 5]) + structureBlob(badChildren) + Data([0]), list: false)
        try await rejectStructure(Data([1, 0, 5]) + structureBlob(badChildren) + Data([0]), list: true)
    }
}

private func rejectStructure(_ data: Data, list: Bool) async throws {
    if list {
        try await verifyRejectedResponse(
            data, read: { try await $0.listRecords(select: "numbers") },
            watch: { try await $0.subscribeWatchRecords(select: "numbers", handler: $1) })
    } else {
        try await verifyRejectedResponse(
            data, read: { try await $0.getRecord(select: "numbers") },
            watch: { try await $0.subscribeWatchRecord(select: "numbers", handler: $1) })
    }
}

private func verifyStructuredStreams(
    rowClient: LuxoGeneratedClient, columnClient: LuxoGeneratedClient, check: (Record) throws -> Void
) async throws {
    let row = ScalarReceiver<Record>()
    let stopRow = try await rowClient.subscribeWatchRecord(select: "numbers") { row.append($0) }
    stopRow()
    guard row.values.count == 1 else { throw structuredFailure() }
    try check(row.values[0])
    let columns = ScalarReceiver<[Record]>()
    let stopColumns = try await columnClient.subscribeWatchRecords(select: "numbers") { columns.append($0) }
    stopColumns()
    guard columns.values.count == 1, columns.values[0].count == 1 else { throw structuredFailure() }
    try check(columns.values[0][0])
}

private func verifyRecordPages() async throws {
    let maximum = Data([0xfe] + Array(repeating: 0xff, count: 8) + [1])
    let trailer = maximum + maximum + maximum
    for nonempty in [false, true] {
        let columns = nonempty ? Data([1, 0, 1]) + maximum + Data([0]) : Data([0, 0, 0])
        let wire = columns + trailer
        let items = nonempty ? #"[{"id":9223372036854775807}]"# : "[]"
        let json = Data(
            "{\"items\":\(items),\"total\":9223372036854775807,\"page\":9223372036854775807,\"pageSize\":9223372036854775807}"
                .utf8)
        for binary in [false, true] {
            let page = try await structuredClient(binary ? wire : json, binary: binary).listRecordPage(select: "id")
            guard page.total == Int.max, page.page == Int.max, page.pageSize == Int.max,
                page.items.count == (nonempty ? 1 : 0)
            else { throw structuredFailure() }
            if nonempty, try page.items[0].id.requireValue() != Int.max { throw structuredFailure() }
        }
        for count in 0..<wire.count { try await rejectPage(Data(wire.prefix(count))) }
        try await rejectPage(wire + Data([99]))
        let overflow = Data(Array(repeating: UInt8(0xff), count: 9) + [2])
        for index in 0..<3 {
            let values = (0..<3).map { $0 == index ? overflow : maximum }
            try await rejectPage(columns + values.reduce(Data(), +))
        }
    }
    let page = try await structuredClient(Data([0, 0, 0, 0, 0, 0]), binary: true).listRecordPage(select: "id")
    guard page.items.isEmpty, page.total == 0, page.page == 0, page.pageSize == 0 else { throw structuredFailure() }
}

private func rejectPage(_ data: Data) async throws {
    do {
        _ = try await structuredClient(data, binary: true).listRecordPage(select: "id")
        throw structuredFailure()
    } catch let error as LuxoError where error.name == "DecodeError" {}
}

private func verifyPaginationParameters() async throws {
    for supplied in [false, true] {
        let client = try LuxoGeneratedClient(transport: PaginationTransport(supplied: supplied))
        _ = try await client.listRecordPage(
            page: supplied ? 2 : nil, pageSize: supplied ? 20 : nil, select: "id")
    }
}

private struct PaginationTransport: ConsumerTransport {
    let supplied: Bool

    func call(_ api: String, request: any GeneratedRequest) async throws -> TransportPayload {
        var encoder = Encoder()
        try request.writeParameters(to: &encoder)
        let params = try request.toJSONParameters()
        guard api == "listRecordPage", request.apiID == 5,
            encoder.data == (supplied ? Data([7, 4, 9, 40]) : Data()),
            params["page"] == (supplied ? .int(2) : nil),
            params["pageSize"] == (supplied ? .int(20) : nil)
        else { throw structuredFailure() }
        return TransportPayload(data: Data([0, 0, 0, 0, 0, 0]), mode: .binary)
    }

    func call(_ api: String, params: [String: LuxoValue]?) async throws -> TransportPayload {
        throw structuredFailure()
    }
    func setToken(_ token: String) {}
    func setMode(_ mode: TransportMode) {}
    func setSchema(_ schema: [String: APISchema]) {}
}

private func structureBlob(_ data: Data) -> Data {
    precondition(data.count < 128)
    return Data([UInt8(data.count)]) + data
}

private func binaryDepthPayload(_ layers: Int, lists: Bool, jsonLayers: Int) -> (row: Data, columns: Data) {
    let json = Data(
        (String(repeating: "[", count: jsonLayers) + "null" + String(repeating: "]", count: jsonLayers)).utf8)
    var documents = Encoder()
    documents.writeVarint(1)
    documents.writeBytes(json)
    func leaf(columns: Bool) -> Data {
        var encoder = Encoder()
        if columns { encoder.writeVarint(1) }
        encoder.writeVarint(4)
        encoder.writeVarint(1); encoder.writeBool(true); encoder.writeBytes(json)
        encoder.writeVarint(2); encoder.writeBool(true)
        if columns { encoder.writeBytes(documents.data) } else { encoder.writeRawBytes(documents.data) }
        encoder.writeVarint(3); encoder.writeBool(false)
        encoder.writeVarint(4); encoder.writeBool(true); encoder.writeBytes(Data([0, 0, 0]))
        encoder.writeVarint(5); encoder.writeBool(true); encoder.writeString("leaf")
        encoder.writeVarint(0)
        return encoder.data
    }
    var row = leaf(columns: false)
    var columns = leaf(columns: true)
    for _ in 1..<layers {
        let payload = lists ? columns : row
        var field = Encoder()
        field.writeVarint(lists ? 4 : 3); field.writeBool(true); field.writeBytes(payload); field.writeVarint(0)
        row = Data([0]) + field.data
        columns = Data([1, 0]) + field.data
    }
    return (row, columns)
}

private func checkBinaryDepthNode(_ input: DepthNode, layers: Int, lists: Bool, jsonLayers: Int) throws {
    var node = input
    for _ in 1..<layers {
        if lists {
            guard let children = try node.children.requireValue(), children.count == 1 else {
                throw structuredFailure()
            }
            node = children[0]
        } else {
            guard let child = try node.child.requireValue() else { throw structuredFailure() }
            node = child
        }
    }
    var json = JSONValue.null
    for _ in 0..<jsonLayers { json = .array([json]) }
    guard try node.metadata.requireValue() == json, try node.documents.requireValue() == [json],
        try node.child.requireValue() == nil, try node.children.requireValue()?.isEmpty == true,
        try node.depth.requireValue() == "leaf"
    else { throw structuredFailure() }
}

private func verifyGeneratedBinaryModelDepth() async throws {
    var failures: [String] = []
    for lists in [false, true] {
        for layers in [63, 64, 65] {
            let wire = binaryDepthPayload(layers, lists: lists, jsonLayers: 128)
            let rowClient = try structuredClient(wire.row, binary: true)
            let columnClient = try structuredClient(wire.columns, binary: true)
            let pageClient = try structuredClient(wire.columns + Data([2, 2, 2]), binary: true)
            let reads: [(String, () async throws -> [DepthNode])] = [
                ("directRow", { [try decodeLuxoResponse(wire.row) { try decodeDepthNode(&$0) }] }),
                ("directColumns", { try decodeColumnarDepthNode(wire.columns) }),
                ("initialColumns", { try decodeColumnarDepthNode(ColumnarDecoder(data: wire.columns)) }),
                ("directPage", { try decodePaginatedDepthNode(wire.columns + Data([2, 2, 2])).items }),
                (
                    "initialPage",
                    { try decodePaginatedDepthNode(ColumnarDecoder(data: wire.columns + Data([2, 2, 2]))).items }
                ),
                ("callRow", { [try await rowClient.getDepthNode(select: "metadata,documents,child,children,depth")] }),
                (
                    "callColumns",
                    { try await columnClient.listDepthNodes(select: "metadata,documents,child,children,depth") }
                ),
                (
                    "callPage",
                    { try await pageClient.listDepthNodePage(select: "metadata,documents,child,children,depth").items }
                ),
            ]
            for (name, read) in reads {
                let label = "\(name)/\(lists)/\(layers)"
                do {
                    let nodes = try await read()
                    if layers > 64 { failures.append("accepted \(label)"); continue }
                    guard nodes.count == 1 else { throw structuredFailure() }
                    try checkBinaryDepthNode(nodes[0], layers: layers, lists: lists, jsonLayers: 128)
                } catch let error as LuxoError
                    where layers > 64 && error.name == "DecodeError" && error.message.contains("64")
                {
                } catch { failures.append("unexpected \(label): \(error)") }
            }
            if layers <= 64 {
                try await verifyBinaryDepthStreams(rowClient, columnClient, layers: layers, lists: lists)
            } else {
                failures += try await rejectedBinaryDepthStreams(rowClient, columnClient).map { "\($0)/\(lists)" }
            }
        }
    }
    if !failures.isEmpty {
        throw LuxoError(code: 0, message: failures.joined(separator: "; "), name: "ConsumerError")
    }
    print("Generated Binary rows/columns/pages/calls/streams preserve JSON128 and model64; model65 rejected")
}

private func rejectedBinaryDepthStreams(
    _ rowClient: LuxoGeneratedClient, _ columnClient: LuxoGeneratedClient
) async throws -> [String] {
    let received = ScalarReceiver<Bool>()
    let errors = ScalarReceiver<LuxoError>()
    let observer = StreamObserver(onError: { errors.append($0) })
    let stopRow = try await rowClient.subscribeWatchDepthNode(select: "child,children", observer: observer) { _ in
        received.append(true)
    }
    stopRow()
    let stopColumns = try await columnClient.subscribeWatchDepthNodes(select: "child,children", observer: observer) {
        _ in received.append(true)
    }
    stopColumns()
    guard received.values.isEmpty, errors.values.count == 2,
        errors.values.allSatisfy({ $0.name == "DecodeError" && $0.message.contains("64") })
    else { return ["model65 stream invoked success or missed depth error"] }
    return []
}

private func verifyBinaryDepthDiscardedColumns() async throws {
    var failures: [String] = []
    for lists in [false, true] {
        for layers in [64, 65] {
            let wire = binaryDepthPayload(layers, lists: lists, jsonLayers: 128)
            let id: UInt8 = lists ? 4 : 3
            let duplicate = Data(wire.columns.dropLast()) + Data([id, 0, 0])
            do {
                let nodes = try await structuredClient(duplicate, binary: true).listDepthNodes(select: "child,children")
                if layers > 64 { failures.append("discarded model65/\(lists)"); continue }
                guard nodes.count == 1 else { throw structuredFailure() }
                if lists {
                    guard try nodes[0].children.requireValue() == nil else { throw structuredFailure() }
                } else {
                    guard try nodes[0].child.requireValue() == nil else { throw structuredFailure() }
                }
            } catch let error as LuxoError
                where layers > 64 && error.name == "DecodeError" && error.message.contains("64")
            {
            } catch { failures.append("discarded model unexpected: \(error)") }
            if layers == 64 {
                let cell = Data(wire.columns.dropFirst(3).dropLast())
                let siblings = Data([2, 0, id]) + cell + cell + Data([0])
                let nodes = try decodeColumnarDepthNode(siblings)
                guard nodes.count == 2 else { throw structuredFailure() }
                for node in nodes { try checkBinaryDepthNode(node, layers: 64, lists: lists, jsonLayers: 128) }
            }
        }
    }
    let json129 = binaryDepthPayload(1, lists: false, jsonLayers: 129)
    let overwrittenJSON = Data(json129.columns.dropLast()) + Data([1, 0, 2, 0, 0])
    do {
        _ = try await structuredClient(overwrittenJSON, binary: true).listDepthNodes(select: "metadata,documents")
        failures.append("discarded JSON129")
    } catch let error as LuxoError where error.name == "DecodeError" && error.message.contains("invalid JSON") {
    } catch { failures.append("discarded JSON unexpected: \(error)") }
    let rawJSON = Data((String(repeating: "[", count: 129) + "null" + String(repeating: "]", count: 129)).utf8)
    for field in [1, 2] {
        var cell = Encoder()
        if field == 2 { cell.writeVarint(1) }
        cell.writeBytes(rawJSON)
        var columns = Encoder()
        columns.writeVarint(1); columns.writeVarint(0); columns.writeVarint(UInt64(field)); columns.writeBool(true)
        if field == 1 { columns.writeBytes(rawJSON) } else { columns.writeBytes(cell.data) }
        columns.writeVarint(UInt64(field)); columns.writeBool(false); columns.writeVarint(0)
        do {
            _ = try await structuredClient(columns.data, binary: true).listDepthNodes(select: "metadata,documents")
            failures.append("discarded JSON129 field\(field)")
        } catch let error as LuxoError where error.name == "DecodeError" && error.message.contains("invalid JSON") {
        } catch { failures.append("discarded JSON field\(field) unexpected: \(error)") }
    }
    let discardedArray = Data([1, 0, 4]) + structureBlob(Data([1])) + Data([4]) + structureBlob(Data([0])) + Data([0])
    do { try await rejectStructure(discardedArray, list: true) } catch {
        failures.append("discarded invalid array: \(error)")
    }
    for paginated in [false, true] {
        do {
            let client = try structuredClient(json129.columns + (paginated ? Data([2, 2, 2]) : Data()), binary: true)
            if paginated {
                _ = try await client.listDepthNodePage(select: "metadata,documents")
            } else {
                _ = try await client.listDepthNodes(select: "metadata,documents")
            }
            failures.append("JSON129 accepted/\(paginated)")
        } catch let error as LuxoError where error.name == "DecodeError" && error.message.contains("invalid JSON") {
        } catch { failures.append("JSON129 wrong error/\(paginated): \(error)") }
    }
    if !failures.isEmpty { throw LuxoError(code: 0, message: failures.joined(separator: "; "), name: "ConsumerError") }
    print("Generated Binary discarded model/JSON columns remain checked; valid last-null and sibling64 preserved")
}

private func verifyBinaryRequiredModelDepth() throws {
    var failures: [String] = []
    for lists in [false, true] {
        for layers in [63, 64] {
            let wire = binaryDepthPayload(layers, lists: lists, jsonLayers: 128)
            var fields = Encoder()
            fields.writeVarint(1); fields.writeBytes(wire.row)
            fields.writeVarint(2); fields.writeBytes(wire.columns); fields.writeVarint(0)
            let row = Data([0]) + fields.data
            let columns = Data([1, 0]) + fields.data
            let reads: [(String, () throws -> [DepthEnvelope])] = [
                ("row", { [try decodeLuxoResponse(row) { try decodeDepthEnvelope(&$0) }] }),
                ("columns", { try decodeColumnarDepthEnvelope(columns) }),
                ("page", { try decodePaginatedDepthEnvelope(columns + Data([2, 2, 2])).items }),
            ]
            for (name, read) in reads {
                do {
                    let values = try read()
                    if layers == 64 { failures.append("required wrapper accepted65/\(name)/\(lists)"); continue }
                    guard values.count == 1 else { throw structuredFailure() }
                    let value = values[0]
                    try checkBinaryDepthNode(value.node.requireValue(), layers: layers, lists: lists, jsonLayers: 128)
                    let nodes = try value.nodes.requireValue()
                    guard nodes.count == 1 else { throw structuredFailure() }
                    try checkBinaryDepthNode(nodes[0], layers: layers, lists: lists, jsonLayers: 128)
                } catch let error as LuxoError
                    where layers == 64 && error.name == "DecodeError" && error.message.contains("64")
                {
                } catch { failures.append("required wrapper unexpected/\(name)/\(lists): \(error)") }
            }
        }
    }
    if !failures.isEmpty { throw LuxoError(code: 0, message: failures.joined(separator: "; "), name: "ConsumerError") }
    print("Generated required model/list edges propagate model depth across types")
}

private func verifyBinaryDepthStreams(
    _ rowClient: LuxoGeneratedClient, _ columnClient: LuxoGeneratedClient, layers: Int, lists: Bool
) async throws {
    let row = ScalarReceiver<DepthNode>()
    let stopRow = try await rowClient.subscribeWatchDepthNode(select: "metadata,documents,child,children,depth") {
        row.append($0)
    }
    stopRow()
    let columns = ScalarReceiver<[DepthNode]>()
    let stopColumns = try await columnClient.subscribeWatchDepthNodes(select: "metadata,documents,child,children,depth")
    { columns.append($0) }
    stopColumns()
    guard row.values.count == 1, columns.values.count == 1, columns.values[0].count == 1 else {
        throw structuredFailure()
    }
    try checkBinaryDepthNode(row.values[0], layers: layers, lists: lists, jsonLayers: 128)
    try checkBinaryDepthNode(columns.values[0][0], layers: layers, lists: lists, jsonLayers: 128)
}

private func structuredFailure() -> LuxoError {
    LuxoError(
        code: 0, message: "generated structured response changed value or accepted malformed data",
        name: "ConsumerError")
}

func benchmarkBinaryModelReads() throws {
    for (lists, layers, json) in [false, true].flatMap({ lists in [1, 16, 32].map { (lists, $0, 0) } }) + [
        (false, 1, 128)
    ] {
        let wire = binaryDepthPayload(layers, lists: lists, jsonLayers: json)
        let page = wire.columns + Data([2, 2, 2])
        let row = try decodeLuxoResponse(wire.row) { try decodeDepthNode(&$0) }
        let columns = try decodeColumnarDepthNode(wire.columns)
        let paginated = try decodePaginatedDepthNode(page)
        for node in [row] + columns + paginated.items {
            try checkBinaryDepthNode(node, layers: layers, lists: lists, jsonLayers: json)
        }
        let operations: [(String, () throws -> UInt64)] = [
            ("row", { binaryDepthChecksum(try decodeLuxoResponse(wire.row) { try decodeDepthNode(&$0) }) }),
            (
                "columns",
                {
                    let nodes = try decodeColumnarDepthNode(wire.columns)
                    return UInt64(nodes.count) &+ binaryDepthChecksum(nodes[0])
                }
            ),
            (
                "page",
                {
                    let result = try decodePaginatedDepthNode(page)
                    return UInt64(result.total + result.page + result.pageSize) &+ binaryDepthChecksum(result.items[0])
                }
            ),
        ]
        for (kind, operation) in operations {
            try measureBinaryDepthRead("binaryRead/\(kind)/\(lists)/\(layers)/json\(json)", operation: operation)
        }
    }
}

@inline(never)
private func binaryDepthChecksum(_ node: DepthNode) -> UInt64 {
    if case .value(let text) = node.depth { return UInt64(text?.utf8.count ?? 0) }
    return 1
}

@inline(never)
private func measureBinaryDepthRead(_ name: String, operation: () throws -> UInt64) rethrows {
    let iterations = 100
    var checksum: UInt64 = 0
    for _ in 0..<600 { checksum &+= try operation() }
    for batch in 0..<12 {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { checksum &+= try operation() }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations)
        print("\(name)\t\(batch)\t\(elapsed)\t\(checksum)")
    }
}

private func structuredClient(_ data: Data, binary: Bool) throws -> LuxoGeneratedClient {
    let client = try LuxoGeneratedClient(transport: StructuredTransport(data: data, mode: binary ? .binary : .json))
    if binary { client.enableBinary() }
    return client
}

private struct StructuredTransport: ConsumerTransport {
    let data: Data
    let mode: TransportMode
    func call(_ api: String, params: [String: LuxoValue]?) async throws -> TransportPayload {
        TransportPayload(data: data, mode: mode)
    }
    func subscribe<Value: Sendable>(
        _ api: String, decoder: @escaping @Sendable (TransportPayload) throws -> Value,
        params: [String: LuxoValue]?, observer: StreamObserver?,
        handler: @escaping @Sendable (Value) -> Void
    ) async throws -> (@Sendable () -> Void) {
        deliverConsumerPayload(
            TransportPayload(data: data, mode: mode), decoder: decoder, observer: observer, handler: handler)
        return {}
    }
    func setToken(_ token: String) {}
    func setMode(_ mode: TransportMode) {}
    func setSchema(_ schema: [String: APISchema]) {}
}
