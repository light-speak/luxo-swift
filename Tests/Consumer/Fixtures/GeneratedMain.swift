import Foundation
import LuxoClient

// Response-only fixtures inspect JSON projections explicitly; production Binary transports never use this adapter.
protocol ConsumerTransport: Transport {}
extension ConsumerTransport {
    func call(_ api: String, request: any GeneratedRequest) async throws -> TransportPayload {
        try await call(api, params: request.toJSONParameters())
    }
    func subscribe<Value: Sendable>(
        _ api: String, decoder: @escaping @Sendable (TransportPayload) throws -> Value,
        request: any GeneratedRequest, observer: StreamObserver?, handler: @escaping @Sendable (Value) -> Void
    ) async throws -> (@Sendable () -> Void) {
        try await subscribe(
            api, decoder: decoder, params: request.toJSONParameters(), observer: observer, handler: handler)
    }
}

let profile = ProfileInput(name: "Luxo", bio: nil)
var profileEncoder = Encoder()
try profile.writeLuxo(to: &profileEncoder)
guard profileEncoder.data == Data([4, 1, 4, 76, 117, 120, 111, 2, 0, 0]) else {
    throw LuxoError(code: 0, message: "invalid generated input wire format", name: "ConsumerError")
}
_ = Record()
do {
    if CommandLine.arguments.contains("--enum-bench") {
        try await verifyEnums()
        try benchmarkEnums()
    } else if CommandLine.arguments.contains("--decoder-errors-bench") {
        try benchmarkDecoderErrorBoundary()
    } else if CommandLine.arguments.contains("--scalar-bench") {
        try benchmarkScalarResponses()
    } else {
        try verifyRegistrationFailure()
        try await verifyPrecisionInputs()
        try await verifyEnums()
        try await verifyScalarResponses()
        try await verifyStructuredResponses()
        try await verifyJSONProjection()
    }
} catch {
    FileHandle.standardError.write(Data("Consumer failed: \(error)\n".utf8))
    exit(1)
}

func verifyRegistrationFailure() throws {
    do {
        _ = try LuxoGeneratedClient(transport: RejectedSchemaTransport())
    } catch let error as LuxoError where error.name == "ConfigError" && error.message == "registration rejected" {
        return
    }
    throw LuxoError(code: 0, message: "client swallowed schema registration failure", name: "ConsumerError")
}

private struct RejectedSchemaTransport: ConsumerTransport {
    func setSchema(_ schema: [String: APISchema]) throws {
        throw LuxoError(code: 0, message: "registration rejected", name: "ConfigError")
    }
    func setToken(_ token: String) {}
    func setMode(_ mode: TransportMode) {}
    func call(_ api: String, params: [String: LuxoValue]?) async throws -> TransportPayload {
        throw LuxoError(code: 0, message: "uninitialized client called", name: "ConsumerError")
    }
}

func precisionInput(note: String? = nil) -> PrecisionInput {
    PrecisionInput(
        count: Int.max, duration: Int64.min, ratio: 1.25,
        values: [Int.min, 9_007_199_254_740_993, Int.max], ratios: [1.25, 2.5], status: .open,
        blob: Data([0, 255]), uuid: UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!,
        date: "2026-09-13T00:00:00Z", decimal: "12345678901234567890.125", enabled: true,
        metadata: .object(["value": .array([.number(1.25), .null])]),
        profiles: [ProfileInput(name: "nested", bio: note)], note: note)
}

func normalizeProjection(_ value: LuxoValue) throws -> LuxoValue {
    switch value {
    case .structured(let input): return try normalizeProjection(input.luxoJSONValue())
    case .array(let values): return .array(try values.map(normalizeProjection))
    case .object(let values): return .object(try values.mapValues(normalizeProjection))
    default: return value
    }
}

func verifyPrecisionInputs() async throws {
    for note in [nil, "present"] {
        let input = precisionInput(note: note)
        let projection = try normalizeProjection(input.luxoJSONValue())
        let encoded = try LuxoValue.encode(input)
        // Both typed trees retain Bytes as Data; base64 belongs only at the JSON writer boundary.
        guard projection == encoded, case .object(let fields) = encoded, fields["blob"] == .bytes(input.blob) else {
            throw LuxoError(code: 0, message: "JSON projection changed input values", name: "ConsumerError")
        }
        let patches: [(LuxoOptional<String>, LuxoValue?)] = [
            (.absent, nil), (.present(nil), .null), (.present("patch"), .string("patch")),
        ]
        for (patch, expected) in patches {
            let client = try LuxoGeneratedClient(transport: PrecisionTransport(input: input, expectedNote: expected))
            guard try await callPrecision(client, input: input, note: patch) else {
                throw LuxoError(code: 0, message: "generated request failed", name: "ConsumerError")
            }
        }
        let client = try LuxoGeneratedClient(transport: PrecisionTransport(input: input, expectedNote: nil))
        for ratio in [Double.nan, .infinity, -.infinity] {
            do {
                _ = try await callPrecision(client, input: input, ratios: [ratio])
                throw LuxoError(code: 0, message: "non-finite input accepted", name: "ConsumerError")
            } catch let error as LuxoError where error.name == "EncodingError" {}
        }
    }
}

func callPrecision(
    _ client: LuxoGeneratedClient, input: PrecisionInput,
    ratios: [Double] = [1.0, 1.25], note: LuxoOptional<String> = .absent
) async throws -> Bool {
    try await client.checkPrecision(
        count: Int.max, durations: [Int64.min, Int64.max], ratios: ratios,
        statuses: [.open, .closed], blobs: [input.blob], uuids: [input.uuid], dates: [input.date],
        decimals: [input.decimal], flags: [true, false], metadata: [input.metadata], input: input, note: note)
}

struct PrecisionTransport: ConsumerTransport {
    let input: PrecisionInput
    let expectedNote: LuxoValue?

    func call(_ api: String, params: [String: LuxoValue]?) async throws -> TransportPayload {
        var expected: [String: LuxoValue] = [
            "count": .int(Int64.max), "durations": .array([.int(Int64.min), .int(Int64.max)]),
            "ratios": .array([.float(1.0), .float(1.25)]), "statuses": .array(["OPEN", "CLOSED"]),
            "blobs": .array([.bytes(input.blob)]), "uuids": .array([LuxoValue(input.uuid)]),
            "dates": .array([.string(input.date)]), "decimals": .array([.string(input.decimal)]),
            "flags": .array([true, false]), "metadata": .array([LuxoValue(input.metadata)]),
            "input": .structured(input),
        ]
        if let expectedNote { expected["note"] = expectedNote }
        guard api == "checkPrecision", params == expected else {
            throw LuxoError(code: 0, message: "generated parameters lost types or precision", name: "ConsumerError")
        }
        return TransportPayload(data: Data("true".utf8), mode: .json)
    }

    func setToken(_ token: String) {}
    func setMode(_ mode: TransportMode) {}
    func setSchema(_ schema: [String: APISchema]) {}
}

@concurrent
func inspectSelection(client: LuxoGeneratedClient) async throws {
    let record = try await client.getRecord(select: "profile { name }")
    _ = try record.profile.requireValue().map { profile in
        print(try profile.name.requireValue())
    }
}

nonisolated(nonsending)
    func inspectCallerSelection(client: LuxoGeneratedClient) async throws
{
    let record = try await client.getRecord(select: "profile { name }")
    _ = try record.profile.requireValue()?.name.requireValue()
}
