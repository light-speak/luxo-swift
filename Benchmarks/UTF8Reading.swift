// Compile with LuxoClient sources, -O and -whole-module-optimization.
import Dispatch
import Foundation
#if LUXO_UTF8_ALLOCATION
    import Darwin
#endif

@main
enum UTF8ReadingBenchmark {
    enum Shape: Equatable { case row, nullable, column, json, legacy, legacyJSON }

    struct Fixture {
        let name: String
        let shape: Shape
        let data: Data
        let expected: UInt64
        let original: UInt64
    }

    static func main() throws {
        #if LUXO_UTF8_ALLOCATION
            try allocations()
        #else
            let verify = CommandLine.arguments.contains("--verify-original")
            let sample = CommandLine.arguments.first { $0.hasPrefix("--sample=") }.map { String($0.dropFirst(9)) }
            let cases = try fixtures()
            precondition(sample == nil || cases.contains { $0.name == sample }, "unknown sample")
            var failures = 0
            for fixture in cases where sample == nil || fixture.name == sample {
                let actual = try read(fixture)
                if verify {
                    if actual != fixture.original {
                        failures += 1
                        print("mismatch,\(fixture.name),\(actual),\(fixture.original)")
                    }
                    continue
                }
                precondition(actual == fixture.expected, fixture.name)
                _ = try measure(fixture, iterations: 1000)
                var count = 1000
                while try measure(fixture, iterations: count).nanoseconds < 100_000_000 { count *= 2 }
                let result = try measure(fixture, iterations: count)
                precondition(result.checksum == fixture.expected &* UInt64(count))
                print("\(fixture.name),\(Double(result.nanoseconds) / Double(count)),\(result.checksum),\(count)")
            }
            if verify {
                print("original Unicode checks: \(failures) mismatches")
                if failures > 0 { exit(1) }
            }
        #endif
    }

    #if LUXO_UTF8_ALLOCATION
        static func allocations() throws {
            guard let name = CommandLine.arguments.dropFirst().first,
                let fixture = try fixtures().first(where: { $0.name == name })
            else { preconditionFailure("missing allocation sample") }
            var total: UInt64 = 0
            for _ in 0..<100 {
                total &+= try read(fixture)
                let block = allocateCalibrationBlock()
                free(block)
            }
            precondition(total == fixture.expected &* 100)
            print("READY iterations=100 checksum=\(total)")
            fflush(stdout)
            _ = readLine()
        }

        @inline(never)
        static func allocateCalibrationBlock() -> UnsafeMutableRawPointer { malloc(12345)! }
    #endif

    @inline(never)
    static func measure(_ fixture: Fixture, iterations: Int) throws -> (nanoseconds: UInt64, checksum: UInt64) {
        var checksum: UInt64 = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { checksum &+= try read(fixture) }
        return (DispatchTime.now().uptimeNanoseconds - start, checksum)
    }

    @inline(never)
    static func read(_ fixture: Fixture) throws -> UInt64 {
        switch fixture.shape {
        case .row:
            var decoder = Decoder(fixture.data)
            let value = decoder.readString()
            precondition(decoder.error == nil && decoder.isAtEnd)
            return checksum(value)
        case .nullable:
            var decoder = Decoder(fixture.data)
            let value = decoder.readStringPtr()
            precondition(decoder.error == nil && decoder.isAtEnd)
            return checksum(value!)
        case .column:
            var decoder = ColumnarDecoder(data: fixture.data)
            precondition(decoder.nextColumn())
            let values = decoder.readColumnString()
            precondition(!decoder.nextColumn() && decoder.error == nil && decoder.isAtEnd)
            return values.reduce(0) { $0 &+ checksum($1) }
        case .json:
            guard case .string(let value) = try JSONReader.decode(fixture.data) else { preconditionFailure() }
            return checksum(value)
        case .legacy:
            #if LUXO_UTF8_BASELINE
                return checksum(String(data: fixture.data, encoding: .utf8)!)
            #else
                return checksum(strictUTF8String(fixture.data)!)
            #endif
        case .legacyJSON:
            return try fixture.data.withUnsafeBytes { raw in
                let reader = JSONReader(bytes: raw.bindMemory(to: UInt8.self))
                return checksum(try reader.legacyUTF8(0..<raw.count))
            }
        }
    }

    static func checksum(_ value: String) -> UInt64 {
        UInt64(value.utf8.count) &+ UInt64(value.utf8.first ?? 0) &+ 1
    }

    static func fixtures() throws -> [Fixture] {
        let short = "abcdefghijklmnop"
        let bom = "\u{feff}hello"
        let chinese = String(repeating: "发布检查", count: 350)
        var result: [Fixture] = []
        for (name, shape, text): (String, Shape, String) in [
            ("row_empty", .row, ""), ("row_short", .row, short),
            ("row_72k", .row, String(repeating: "中文", count: 12288)), ("row_bom", .row, bom),
            ("nullable_short", .nullable, short), ("nullable_bom", .nullable, bom),
            ("column128_short", .column, short), ("column128_bom", .column, bom),
            ("json_short_control", .json, short), ("json_4k_control", .json, chinese),
            ("legacy_short", .legacy, short), ("legacy_4k", .legacy, chinese), ("legacy_bom", .legacy, bom),
            ("legacy_json_short_control", .legacyJSON, short), ("legacy_json_bom_control", .legacyJSON, bom),
        ] {
            var expected = text
            #if LUXO_UTF8_BASELINE
                if [.row, .nullable, .column, .legacy].contains(shape) && text.utf8.starts(with: [0xef, 0xbb, 0xbf]) {
                    expected = String(decoding: text.utf8.dropFirst(3), as: UTF8.self)
                }
            #endif
            result.append(
                Fixture(
                    name: name, shape: shape, data: try payload(text, shape: shape),
                    expected: checksum(expected) &* (shape == .column ? 128 : 1),
                    original: checksum(text) &* (shape == .column ? 128 : 1)))
        }
        return result
    }

    static func payload(_ text: String, shape: Shape) throws -> Data {
        var encoder = Encoder()
        switch shape {
        case .json: return try JSONValue.string(text).jsonData()
        case .legacy, .legacyJSON: return Data(text.utf8)
        case .row: encoder.writeString(text)
        case .nullable:
            encoder.writeBool(true)
            encoder.writeString(text)
        case .column:
            encoder.writeVarint(128)
            encoder.writeVarint(UInt64(text.utf8.count * 128))
            encoder.writeVarint(1)
            for _ in 0..<128 { encoder.writeString(text) }
            encoder.writeEnd()
        }
        return encoder.data
    }
}
