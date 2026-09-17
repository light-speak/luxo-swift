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
        let rowClient = structuredClient(binary ? row : Data(json.utf8), binary: binary)
        try check(try await rowClient.getRecord(select: "numbers, profile { name, bio }, profiles { name, bio }"))
        let columnClient = structuredClient(binary ? columns : Data("[\(json)]".utf8), binary: binary)
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

private func structureBlob(_ data: Data) -> Data {
    precondition(data.count < 128)
    return Data([UInt8(data.count)]) + data
}

private func structuredFailure() -> LuxoError {
    LuxoError(
        code: 0, message: "generated structured response changed value or accepted malformed data",
        name: "ConsumerError")
}

private func structuredClient(_ data: Data, binary: Bool) -> LuxoGeneratedClient {
    let client = LuxoGeneratedClient(transport: StructuredTransport(data: data, mode: binary ? .binary : .json))
    if binary { client.enableBinary() }
    return client
}

private struct StructuredTransport: Transport {
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
