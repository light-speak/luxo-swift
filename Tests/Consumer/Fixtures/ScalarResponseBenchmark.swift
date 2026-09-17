import Foundation
import LuxoClient

func benchmarkDecoderErrorBoundary() throws {
    try compareScalarBoundary("integer decoder error boundary", fixtures: [Data([2])], labels: ("previous", "current"))
    {
        data, checked in
        let value =
            checked
            ? try decodeLuxoResponse(data) { $0.readSvarint() }
            : try previousResponseBoundary(data) { $0.readSvarint() }
        precondition(value == 1)
        return UInt64(value)
    }
    for invalid in [false, true] {
        let payload = invalid ? Data([1, 123]) : Data([2, 123, 125])
        try compareScalarBoundary(
            "JSON decoder boundary invalid=\(invalid)", fixtures: [payload], labels: ("previous", "current")
        ) {
            data, checked in
            do {
                let value =
                    checked
                    ? try decodeLuxoResponse(data) { try JSONValue.parse($0.readBytes()) }
                    : try previousResponseBoundary(data) { try JSONValue.parse($0.readBytes()) }
                precondition(!invalid && value == .object([:]))
                return 1
            } catch let error as LuxoError {
                precondition(invalid && error.name == (checked ? "DecodeError" : "ParseError"))
                return UInt64(error.message.utf8.count)
            }
        }
    }
}

// Frozen generated boundary before normalizing embedded-JSON errors; benchmark-only.
@inline(__always)
private func previousResponseBoundary<Value>(_ data: Data, read: (inout Decoder) throws -> Value) throws -> Value {
    var decoder = Decoder(data)
    let value: Value
    do {
        value = try read(&decoder)
    } catch let error as LuxoError {
        throw error
    } catch {
        throw LuxoError(code: 0, message: decoder.error ?? "invalid response payload", name: "DecodeError")
    }
    if let error = decoder.error { throw LuxoError(code: 0, message: error, name: "DecodeError") }
    guard decoder.isAtEnd else { throw LuxoError(code: 0, message: "trailing response bytes", name: "DecodeError") }
    return value
}

func benchmarkScalarResponses() throws {
    let values: [Int64] = [0, -1, 1, 9_007_199_254_740_993, Int64.min, Int64.max]
    let scalars = values.map { value in
        var encoder = Encoder()
        encoder.writeSvarint(value)
        return encoder.data
    }
    let lists = values.map { value in
        var encoder = Encoder()
        encoder.writeArrayHeader(16)
        for _ in 0..<16 { encoder.writeSvarint(value) }
        return encoder.data
    }
    for index in values.indices {
        let scalar = try decodeLuxoResponse(scalars[index]) { $0.readSvarint() }
        let list = try decodeLuxoResponse(lists[index]) { $0.readArray { $0.readSvarint() } }
        precondition(scalar == values[index] && list == Array(repeating: scalar, count: 16))
    }
    try compareScalarBoundary("integer response", fixtures: scalars) { data, checked in
        if checked { return UInt64(bitPattern: try decodeLuxoResponse(data) { $0.readSvarint() }) }
        var decoder = Decoder(data)
        return UInt64(bitPattern: decoder.readSvarint())
    }
    try compareScalarBoundary("16-integer response", fixtures: lists) { data, checked in
        let values: [Int64]
        if checked {
            values = try decodeLuxoResponse(data) { $0.readArray { $0.readSvarint() } }
        } else {
            var decoder = Decoder(data)
            values = decoder.readArray { $0.readSvarint() }
        }
        return UInt64(values.count) ^ UInt64(bitPattern: values.last!)
    }
}

private func compareScalarBoundary(
    _ label: String, fixtures: [Data], labels: (String, String) = ("unchecked", "checked"),
    operation: (Data, Bool) throws -> UInt64
) rethrows {
    var checksum: UInt64 = 0
    for _ in 0..<8 {
        checksum ^= try measureScalarBoundary(fixtures, checked: false, iterations: 10_000, operation: operation).sum
        checksum ^= try measureScalarBoundary(fixtures, checked: true, iterations: 10_000, operation: operation).sum
    }
    var before: [Double] = []
    var after: [Double] = []
    for index in 0..<16 {
        for checked in index.isMultiple(of: 2) ? [false, true] : [true, false] {
            let sample = try measureScalarBoundary(fixtures, checked: checked, iterations: 50_000, operation: operation)
            checksum &+= sample.sum
            if checked { after.append(sample.ns) } else { before.append(sample.ns) }
        }
    }
    before.sort()
    after.sort()
    let old = (before[7] + before[8]) / 2
    let current = (after[7] + after[8]) / 2
    print(
        "\(label): \(labels.0)=\(old)ns \(labels.1)=\(current)ns delta=\((current / old - 1) * 100)% checksum=\(checksum)"
    )
}

@inline(never)
private func measureScalarBoundary(
    _ fixtures: [Data], checked: Bool, iterations: Int, operation: (Data, Bool) throws -> UInt64
) rethrows -> (ns: Double, sum: UInt64) {
    var sum: UInt64 = 0
    let start = DispatchTime.now().uptimeNanoseconds
    for index in 0..<iterations { sum &+= try operation(fixtures[index % fixtures.count], checked) }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    return (Double(elapsed) / Double(iterations), sum)
}
