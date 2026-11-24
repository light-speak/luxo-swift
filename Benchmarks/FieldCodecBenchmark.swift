// Define LUXO_LEGACY_FIELD_BASELINE only when comparing against an archived SDK.
import Dispatch
import Foundation
import LuxoClient

@main
private struct FieldCodecBenchmark {
    private struct Sample {
        let name: String
        let iterations: Int
        let bytes: [Data]
        let operation: (Int) throws -> UInt64
    }

    static func main() throws {
        for sample in try samples() {
            try saveVectors(sample)
            for index in 0..<1000 { _ = try sample.operation(index) }
            for repetition in 0..<3 {
                let result = try measure(sample)
                print("measure,\(sample.name),\(repetition),\(sample.iterations),\(result.0),\(result.1)")
            }
        }
    }

    @inline(never)
    private static func measure(_ sample: Sample) throws -> (Double, UInt64) {
        let first = try sample.operation(0)
        let second = try sample.operation(1)
        let expected = (first &+ second) &* UInt64(sample.iterations / 2)
        var checksum: UInt64 = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<sample.iterations { checksum &+= try sample.operation(index) }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        precondition(checksum == expected)
        return (Double(elapsed) / Double(sample.iterations), checksum)
    }

    private static func encoded(
        _ name: String, iterations: Int = 300_000, write: @escaping (inout Encoder, Int) throws -> Void
    ) throws -> Sample {
        let make: (Int) throws -> Data = { index in
            var encoder = Encoder()
            try write(&encoder, index)
            return encoder.data
        }
        return Sample(
            name: name, iterations: iterations, bytes: [try make(0), try make(1)],
            operation: { index in fingerprint(try make(index & 1)) })
    }

    private static func samples() throws -> [Sample] {
        let short = ["hello", "\u{feff}東京"]
        let long = String(repeating: "中文", count: 12_288)
        let json = JSONValue.object([
            "id": .integer(Int64.max), "label": .string("\u{feff}東京"),
            "amount": .rawNumber(try JSONNumber("123456789012345678901234567890.123456789")),
        ])
        let dates = [Date(timeIntervalSince1970: -0.001), Date(timeIntervalSince1970: 1_700_000_000.125)]
        return [
            try encoded("typed-int") { encoder, index in
                encoder.writeVarint(1)
                encoder.writeSvarint(index == 0 ? 42 : Int64.max)
                encoder.writeBool(index == 0)
            },
            try encoded("typed-float") { encoder, index in
                encoder.writeVarint(1)
                try encoder.writeFixed64(index == 0 ? -0.0 : Double.leastNonzeroMagnitude)
            },
            try encoded("typed-short-string") { encoder, index in encoder.writeString(short[index]) },
            try encoded("typed-long-string", iterations: 20_000) { encoder, _ in encoder.writeString(long) },
            try encoded("typed-int-list", iterations: 30_000) { encoder, index in
                try encoder.writeArrayHeader(128)
                for value in 0..<128 { encoder.writeSvarint(Int64(value + index)) }
            },
            try encoded("typed-json", iterations: 50_000) { encoder, _ in try encoder.writeJSON(json) },
            try encoded("typed-date-text", iterations: 100_000) { encoder, _ in
                try encoder.writeDateTime("2026-11-06T12:34:56.123456789Z")
            },
            try encoded("native-date-field") { encoder, index in
                #if LUXO_LEGACY_FIELD_BASELINE
                    try encoder.writeField(1, value: dates[index], type: "DateTime")
                #else
                    encoder.writeVarint(1)
                    try encoder.writeDateTime(dates[index])
                #endif
            },
            decoderControl(),
        ]
    }

    private static func decoderControl() -> Sample {
        var encoder = Encoder()
        encoder.writeSvarint(Int64.max)
        encoder.writeBool(true)
        let input = encoder.data
        return Sample(name: "decoder-control", iterations: 500_000, bytes: [input, input]) { _ in
            var decoder = Decoder(input)
            let value = decoder.readSvarint()
            let flag = decoder.readBool()
            precondition(decoder.error == nil && decoder.remaining == 0 && value == Int64.max && flag)
            return UInt64(bitPattern: value) ^ 1
        }
    }

    private static func fingerprint(_ data: Data) -> UInt64 {
        UInt64(data.count) &* 257 &+ UInt64(data.first ?? 0) &+ UInt64(data.last ?? 0)
    }

    private static func saveVectors(_ sample: Sample) throws {
        guard let directory = ProcessInfo.processInfo.environment["LUXO_FIELD_ARTIFACT_DIR"] else { return }
        let target = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for (index, data) in sample.bytes.enumerated() {
            try data.write(to: target.appendingPathComponent("\(sample.name)-\(index).bin"))
        }
    }
}
