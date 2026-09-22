import Foundation
import LuxoClient

func verifyEnums() async throws {
    try verifyEnumIdentity()
    try verifyEnumModels()
    let value = Status(rawValue: "FUTURE")
    let cases: [(LuxoOptional<Status>, [Status]?, [String: LuxoValue])] = [
        (.absent, nil, ["state": "FUTURE"]),
        (.present(nil), [], ["state": "FUTURE", "optional": .null, "states": .array([])]),
        (
            .present(value), [.open, value],
            [
                "state": "FUTURE", "optional": "FUTURE", "states": .array(["OPEN", "FUTURE"]),
            ]
        ),
    ]
    for (optional, states, expected) in cases {
        let client = try LuxoGeneratedClient(transport: EnumParameterTransport(expected: expected))
        guard try await client.enumOptions(state: value, optional: optional, states: states) else {
            throw enumFailure("enum parameter response")
        }
    }
    print("Generated explicit Unknown enums preserve exact text, model cells and parameter presence")
}

private func verifyEnumIdentity() throws {
    guard Status.knownCases == [.open, .closed, .k], Status(rawValue: "OPEN") == .open else {
        throw enumFailure("known members")
    }
    let raws = ["FUTURE", "", "open", "K", "é", "e\u{301}"]
    guard Set(raws.map { Status(rawValue: $0) }).count == raws.count else {
        throw enumFailure("distinct raw enum values collapsed")
    }
    for raw in raws {
        let value = Status(rawValue: raw)
        switch value {
        case .open, .closed, .k: throw enumFailure("unknown member became known")
        case .unknown(let preserved):
            guard preserved.utf8.elementsEqual(raw.utf8) else { throw enumFailure("unknown text changed") }
        }
        let json = try JSONEncoder().encode(value)
        guard try JSONDecoder().decode(Status.self, from: json) == value else { throw enumFailure("Codable") }
    }
    let escaped = [
        "OPEN", "open", "UNKNOWN", "unknown", "case", "init", "self", "quote\"", "slash\\", "line\n", "é", "e\u{301}",
    ]
    guard EscapedStatus.knownCases.count == escaped.count, Set(EscapedStatus.knownCases).count == escaped.count else {
        throw enumFailure("escaped members collided")
    }
    for raw in escaped {
        let value = EscapedStatus(rawValue: raw)
        if case .unknown = value { throw enumFailure("declared escaped member became unknown") }
        guard value.rawValue.utf8.elementsEqual(raw.utf8) else { throw enumFailure("escaped raw text") }
    }
}

private func verifyEnumModels() throws {
    let future = Status(rawValue: "FUTURE")
    for optional in [nil, future] {
        let input = EnumRecordInput(
            state: future, optional: optional, states: [.open, future], optionalStates: optional.map { [$0] })
        var encoder = Encoder()
        try input.writeLuxo(to: &encoder)
        let row = try decodeLuxoResponse(encoder.data, read: decodeEnumRecord)
        try checkEnumRecord(row, optional: optional)
        let json = try JSONEncoder().encode(input)
        let record = try JSONDecoder().decode(EnumRecord.self, from: json)
        guard try record.state.requireValue() == future, try record.states.requireValue() == [.open, future] else {
            throw enumFailure("JSON enum model")
        }
        let projection = try input.luxoJSONValue()
        guard case .object(let fields) = projection, fields["state"] == "FUTURE",
            fields["states"] == .array(["OPEN", "FUTURE"]),
            fields["optional"] == optional.map({ .string($0.rawValue) })
        else {
            throw enumFailure("static enum projection")
        }
        let columns = try decodeColumnarEnumRecord(enumColumns(optional: optional))
        guard columns.count == 1 else { throw enumFailure("column row count") }
        try checkEnumRecord(columns[0], optional: optional)
    }
}

private func checkEnumRecord(_ record: EnumRecord, optional: Status?) throws {
    guard try record.state.requireValue() == .unknown("FUTURE"),
        try record.optional.requireValue() == optional,
        try record.states.requireValue() == [.open, .unknown("FUTURE")],
        try record.optionalStates.requireValue() == optional.map({ [$0] })
    else {
        throw enumFailure("row or column enum model")
    }
}

private func enumColumns(optional: Status?) -> Data {
    var encoder = Encoder()
    encoder.writeVarint(1)
    encoder.writeVarint(0)
    encoder.writeVarint(1)
    encoder.writeString("FUTURE")
    encoder.writeVarint(2)
    encoder.writeBool(optional != nil)
    if let optional { encoder.writeString(optional.rawValue) }
    encoder.writeVarint(3)
    var list = Encoder()
    list.writeArrayHeader(2)
    list.writeString("OPEN")
    list.writeString("FUTURE")
    encoder.writeBytes(list.data)
    encoder.writeVarint(4)
    encoder.writeBool(optional != nil)
    if let optional {
        var nested = Encoder()
        nested.writeArrayHeader(1)
        nested.writeString(optional.rawValue)
        encoder.writeBytes(nested.data)
    }
    encoder.writeEnd()
    return encoder.data
}

private func enumFailure(_ message: String) -> LuxoError {
    LuxoError(code: 0, message: message, name: "ConsumerError")
}

private struct EnumParameterTransport: Transport {
    let expected: [String: LuxoValue]
    func call(_ api: String, params: [String: LuxoValue]?) async throws -> TransportPayload {
        guard api == "enumOptions", params == expected else { throw enumFailure("enum parameter projection") }
        return TransportPayload(data: Data("true".utf8), mode: .json)
    }
    func setToken(_ token: String) {}
    func setMode(_ mode: TransportMode) {}
    func setSchema(_ schema: [String: APISchema]) {}
}

// Frozen closed representation, with the same known members as the generated fixture.
private enum PreviousStatus: String, Codable {
    case open = "OPEN", closed = "CLOSED", k = "K"
}

func benchmarkEnums() throws {
    for count in [1, 128] {
        for binary in [false, true] {
            let raws = ["OPEN", "CLOSED", "K"]
            let fixtures = try raws.map { raw in
                let values = Array(repeating: raw, count: count)
                if !binary { return try JSONEncoder().encode(values) }
                var encoder = Encoder()
                encoder.writeArrayHeader(count)
                for value in values { encoder.writeString(value) }
                return encoder.data
            }
            try compareScalarBoundary(
                "known enum list binary=\(binary) count=\(count)", fixtures: fixtures,
                labels: ("closed", "explicitUnknown"), iterations: count == 1 ? 50_000 : 2_000
            ) { data, current in
                try enumBenchmarkRead(data, binary: binary, current: current)
            }
        }
    }
    for binary in [false, true] {
        let fixtures = try ["FUTURE", "A_LONG_UNKNOWN_MEMBER_1234567890", "K"].map { raw in
            if !binary { return try JSONEncoder().encode(raw) }
            var encoder = Encoder()
            encoder.writeString(raw)
            return encoder.data
        }
        try compareScalarBoundary(
            "unknown scalar binary=\(binary) NON_EQUIVALENT_plainString", fixtures: fixtures,
            labels: ("string", "explicitUnknown")
        ) { data, current in
            let raw: String
            if binary {
                raw = try decodeLuxoResponse(data) { decoder in
                    let text = decoder.readString()
                    return current ? Status(rawValue: text).rawValue : text
                }
            } else {
                raw =
                    current
                    ? try decodeLuxoJSONResponse(Status.self, from: data).rawValue
                    : try LuxoJSONDecoder().decode(String.self, from: data)
            }
            return UInt64(raw.utf8.count)
        }
    }
    try benchmarkJSONResponseBoundary()
}

@inline(never)
private func enumBenchmarkRead(_ data: Data, binary: Bool, current: Bool) throws -> UInt64 {
    if current {
        let values: [Status] =
            binary
            ? try decodeLuxoResponse(data) { $0.readArray { Status(rawValue: $0.readString()) } }
            : try decodeLuxoJSONResponse([Status].self, from: data)
        return UInt64(values.count + values[0].rawValue.utf8.count + values[values.count - 1].rawValue.utf8.count)
    }
    let values: [PreviousStatus] =
        binary
        ? try decodeLuxoResponse(data) { decoder in
            try decoder.readArray { decoder in
                guard let value = PreviousStatus(rawValue: decoder.readString()) else {
                    throw LuxoError(code: 0, message: "invalid enum", name: "DecodeError")
                }
                return value
            }
        } : try LuxoJSONDecoder().decode([PreviousStatus].self, from: data)
    return UInt64(values.count + values[0].rawValue.utf8.count + values[values.count - 1].rawValue.utf8.count)
}

private func benchmarkJSONResponseBoundary() throws {
    for count in [1, 128] {
        let data = try JSONEncoder().encode(Array(repeating: "精度 café", count: count))
        try compareScalarBoundary(
            "JSON decode error normalization count=\(count)", fixtures: [data],
            labels: ("direct", "normalized"), iterations: count == 1 ? 50_000 : 2_000
        ) { data, current in
            let values =
                current
                ? try decodeLuxoJSONResponse([String].self, from: data)
                : try LuxoJSONDecoder().decode([String].self, from: data)
            return UInt64(values.count + values[0].utf8.count)
        }
    }
}
