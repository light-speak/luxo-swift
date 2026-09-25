import Foundation

#if LUXO_NULLABLE_ROOT_BENCHMARK
    /// Compile the same valid-input harness against the pre-change and current source sets.
    @main
    enum NullableRootBenchmark {
        private enum Shape {
            case integer, text, bytes, array, column
        }

        private struct Fixture {
            let name: String
            let shape: Shape
            let data: Data
            let expected: UInt64
            let iterations: Int
        }

        static func main() throws {
            let smoke = CommandLine.arguments.contains("--smoke")
            for fixture in fixtures() {
                try measure("plain/\(fixture.name)", fixture, smoke: smoke) {
                    try plain(fixture.data, shape: fixture.shape)
                }
                #if !LUXO_NULLABLE_BASELINE
                    let view = (Data([99]) + fixture.data).dropFirst()
                    let present = Data([1]) + fixture.data
                    let presentView = (Data([99]) + present).dropFirst()
                    precondition(view.startIndex == 1 && presentView.startIndex == 1)
                    try measure("view/\(fixture.name)", fixture, smoke: smoke) {
                        try plain(view, shape: fixture.shape)
                    }
                    try measure("present/\(fixture.name)", fixture, smoke: smoke) {
                        try nullable(present, shape: fixture.shape) ?? UInt64.max
                    }
                    try measure("present-view/\(fixture.name)", fixture, smoke: smoke) {
                        try nullable(presentView, shape: fixture.shape) ?? UInt64.max
                    }
                #endif
            }
            #if !LUXO_NULLABLE_BASELINE
                let fixture = Fixture(name: "null", shape: .integer, data: Data([0]), expected: 1, iterations: 100_000)
                try measure("null", fixture, smoke: smoke) {
                    try nullable(fixture.data, shape: fixture.shape) == nil ? 1 : 0
                }
            #endif
            print("Verified all checksums and payload boundaries; codec only, no allocation or network measurement.")
        }

        private static func fixtures() -> [Fixture] {
            var fixtures: [Fixture] = []
            for value: Int64 in [42, .max] {
                var encoder = Encoder()
                encoder.writeSvarint(value)
                fixtures.append(
                    Fixture(
                        name: "int-\(value)", shape: .integer, data: encoder.data,
                        expected: UInt64(bitPattern: value), iterations: 100_000))
            }
            for text in ["abcdefghijklmnop", String(repeating: "发布检查", count: 350)] {
                var encoder = Encoder()
                encoder.writeString(text)
                fixtures.append(
                    Fixture(
                        name: "text-\(text.utf8.count)", shape: .text, data: encoder.data,
                        expected: UInt64(text.utf8.count), iterations: 10_000))
            }
            var bytes = Encoder()
            bytes.writeBytes(Data(repeating: 65, count: 4096))
            fixtures.append(
                Fixture(
                    name: "bytes4096", shape: .bytes, data: bytes.data,
                    expected: 4096, iterations: 10_000))
            for column in [false, true] {
                var encoder = Encoder()
                encoder.writeVarint(128)
                if column { encoder.writeVarint(0); encoder.writeVarint(1) }
                for index in 0..<128 { encoder.writeSvarint(Int64(index)) }
                if column { encoder.writeVarint(0) }
                fixtures.append(
                    Fixture(
                        name: column ? "column128" : "array128",
                        shape: column ? .column : .array, data: encoder.data,
                        expected: 8128, iterations: 2_000))
            }
            return fixtures
        }

        @inline(never)
        private static func plain(_ data: Data, shape: Shape) throws -> UInt64 {
            if shape == .column {
                return try readColumn(ColumnarDecoder(data: data), length: data.count)
            }
            return try readScalar(Decoder(data), shape: shape)
        }

        #if !LUXO_NULLABLE_BASELINE
            @inline(never)
            private static func nullable(_ data: Data, shape: Shape) throws -> UInt64? {
                if try isNullRoot(data) { return nil }
                if shape == .column {
                    return try readColumn(ColumnarDecoder(data: data, offset: 1), length: data.count)
                }
                return try readScalar(Decoder(data, offset: 1), shape: shape)
            }
        #endif

        private static func readScalar(_ input: Decoder, shape: Shape) throws -> UInt64 {
            var decoder = input
            let result: UInt64
            switch shape {
            case .integer: result = UInt64(bitPattern: decoder.readSvarint())
            case .text: result = UInt64(decoder.readString().utf8.count)
            case .bytes: result = UInt64(decoder.readBytes().count)
            case .array: result = decoder.readArray { $0.readSvarint() }.reduce(0) { $0 &+ UInt64(bitPattern: $1) }
            case .column: preconditionFailure("column fixture must use its typed reader")
            }
            guard decoder.error == nil && decoder.isAtEnd else {
                throw LuxoError(code: 0, message: "incomplete benchmark scalar", name: "DecodeError")
            }
            return result
        }

        private static func readColumn(_ input: ColumnarDecoder, length: Int) throws -> UInt64 {
            var decoder = input
            precondition(decoder.count == 128 && decoder.nextColumn() && decoder.fieldID == 1)
            let values = decoder.readColumnInt()
            guard values.count == 128 && !decoder.nextColumn() && decoder.error == nil && decoder.offset == length
            else {
                throw LuxoError(code: 0, message: "incomplete benchmark column", name: "DecodeError")
            }
            return values.reduce(0) { $0 &+ UInt64(bitPattern: $1) }
        }

        private static func measure(
            _ label: String, _ fixture: Fixture, smoke: Bool, operation: () throws -> UInt64
        ) throws {
            let checked = try operation()
            precondition(checked == fixture.expected)
            let iterations = smoke ? 1 : fixture.iterations
            let warmup = smoke ? 1 : max(1000, iterations / 5)
            var checksum: UInt64 = 0
            for _ in 0..<warmup { checksum &+= try operation() }
            var samples: [Double] = []
            for _ in 0..<10 {
                let start = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<iterations { checksum &+= try operation() }
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations))
            }
            let checkedAfter = try operation()
            precondition(checkedAfter == fixture.expected)
            precondition(checksum == fixture.expected &* UInt64(warmup + 10 * iterations))
            let sorted = samples.sorted()
            print("\(label) median_ns=\((sorted[4] + sorted[5]) / 2) samples=\(samples) checksum=\(checksum)")
        }
    }
#endif
