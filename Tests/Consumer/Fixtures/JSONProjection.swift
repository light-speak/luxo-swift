import Foundation
import LuxoClient

func verifyJSONProjection() async throws {
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
    try verifyProjectionExceptions()
    try verifyProjectionNamesAndEmptySchema()
    let empty = try await projectionClient("[]").listRecords(select: "id")
    guard empty.isEmpty else { throw projectionFailure("empty list changed") }
    print("Generated JSON model/type lists reject empty projections; null, generic JSON and empty lists preserved")
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
    } catch is DecodingError {
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

private func projectionClient(_ json: String) -> LuxoGeneratedClient {
    LuxoGeneratedClient(transport: ProjectionTransport(data: Data(json.utf8)))
}

private func projectionFailure(_ message: String) -> LuxoError {
    LuxoError(code: 0, message: message, name: "ConsumerError")
}

private struct ProjectionTransport: Transport {
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
