import Foundation

#if LUXO_METADATA_BENCHMARK
    /// Compare valid payloads against the exact pre-change decoder, never malformed baselines.
    enum CodecMetadataBenchmark {
        static func run() throws {
            for count in [1, 16, 256] {
                compareRow(count)
                compareArray(count)
                compareIntegerColumn(count)
                try compareFloatColumn(count)
                compareUUIDColumn(count)
                compareNullableColumn(count)
            }
        }

        private static func compareRow(_ count: Int) {
            var encoder = Encoder()
            encoder.writeVarint(0)
            let values = integers(count)
            for (index, value) in values.enumerated() {
                encoder.writeVarint(UInt64(index + 1))
                encoder.writeSvarint(value)
            }
            encoder.writeVarint(0)
            let data = encoder.data
            pair("Int64 row \(count)", count: count, expected: checksum(values)) {
                var decoder = LegacyDecoder(data)
                decoder.skipArenaHeader()
                var result = UInt64(count)
                while decoder.nextField() != 0 { result = (result &* 31) &+ UInt64(bitPattern: decoder.readSvarint()) }
                return result
            } after: {
                var decoder = Decoder(data)
                decoder.skipArenaHeader()
                var result = UInt64(count)
                while decoder.nextField() != 0 { result = (result &* 31) &+ UInt64(bitPattern: decoder.readSvarint()) }
                return result
            }
        }

        private static func compareArray(_ count: Int) {
            var encoder = Encoder()
            encoder.writeVarint(UInt64(count))
            let values = integers(count)
            for value in values { encoder.writeSvarint(value) }
            let data = encoder.data
            pair("Int64 array \(count)", count: count, expected: checksum(values)) {
                var decoder = LegacyDecoder(data)
                return checksum(decoder.readArray { $0.readSvarint() })
            } after: {
                var decoder = Decoder(data)
                return checksum(decoder.readArray { $0.readSvarint() })
            }
        }

        private static func compareIntegerColumn(_ count: Int) {
            var encoder = header(count)
            let values = integers(count)
            for value in values { encoder.writeSvarint(value) }
            encoder.writeVarint(0)
            let data = encoder.data
            pair("Int64 column \(count)", count: count, expected: checksum(values)) {
                var decoder = LegacyColumnarDecoder(data: data)
                precondition(decoder.nextColumn())
                return checksum(decoder.readColumnInt())
            } after: {
                var decoder = ColumnarDecoder(data: data)
                precondition(decoder.nextColumn())
                return checksum(decoder.readColumnInt())
            }
        }

        private static func compareFloatColumn(_ count: Int) throws {
            var encoder = header(count)
            let values = (0..<count).map { Double($0) + 1.25 }
            for value in values { try encoder.writeFixed64(value) }
            encoder.writeVarint(0)
            let data = encoder.data
            let sum: ([Double]) -> UInt64 = { $0.reduce(UInt64($0.count)) { $0 &+ $1.bitPattern } }
            pair("Float column \(count)", count: count, expected: sum(values)) {
                var decoder = LegacyColumnarDecoder(data: data)
                precondition(decoder.nextColumn())
                return sum(decoder.readColumnFloat())
            } after: {
                var decoder = ColumnarDecoder(data: data)
                precondition(decoder.nextColumn())
                return sum(decoder.readColumnFloat())
            }
        }

        private static func compareUUIDColumn(_ count: Int) {
            var encoder = header(count)
            let values = (0..<count).map { index -> UUID in
                UUID(uuid: (UInt8(index), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15))
            }
            for value in values { encoder.writeUUID(value) }
            encoder.writeVarint(0)
            let data = encoder.data
            let sum: ([UUID]) -> UInt64 = { $0.reduce(UInt64($0.count)) { $0 &+ UInt64($1.uuid.0) } }
            pair("UUID column \(count)", count: count, expected: sum(values)) {
                var decoder = LegacyColumnarDecoder(data: data)
                precondition(decoder.nextColumn())
                return sum(decoder.readColumnUUID())
            } after: {
                var decoder = ColumnarDecoder(data: data)
                precondition(decoder.nextColumn())
                return sum(decoder.readColumnUUID())
            }
        }

        private static func compareNullableColumn(_ count: Int) {
            var encoder = header(count)
            let values = integers(count).enumerated().map { $0.offset.isMultiple(of: 3) ? nil : $0.element }
            for value in values {
                encoder.writeRawBytes(Data([value == nil ? 0 : 1]))
                if let value { encoder.writeSvarint(value) }
            }
            encoder.writeVarint(0)
            let data = encoder.data
            let sum: ([Int64?]) -> UInt64 = {
                $0.reduce(UInt64($0.count)) { $0 &+ ($1.map { UInt64(bitPattern: $0) } ?? 31) }
            }
            pair("Nullable Int64 column \(count)", count: count, expected: sum(values)) {
                var decoder = LegacyColumnarDecoder(data: data)
                precondition(decoder.nextColumn())
                return sum(decoder.readColumnIntPtr())
            } after: {
                var decoder = ColumnarDecoder(data: data)
                precondition(decoder.nextColumn())
                return sum(decoder.readColumnIntPtr())
            }
        }

        private static func header(_ count: Int) -> Encoder {
            var encoder = Encoder()
            encoder.writeVarint(UInt64(count))
            encoder.writeVarint(0)
            encoder.writeVarint(1)
            return encoder
        }

        private static func integers(_ count: Int) -> [Int64] {
            let values: [Int64] = [.min, .max, -1, 0, 1, 9_007_199_254_740_993]
            return (0..<count).map { values[$0 % values.count] }
        }

        private static func checksum(_ values: [Int64]) -> UInt64 {
            values.reduce(UInt64(values.count)) { ($0 &* 31) &+ UInt64(bitPattern: $1) }
        }

        private static func pair(
            _ name: String, count: Int, expected: UInt64, before: () -> UInt64, after: () -> UInt64
        ) {
            precondition(before() == expected && after() == expected)
            let iterations = max(200, 20_000 / count)
            TransportMetadataBenchmark.compare(
                name, iterations: iterations, warmup: max(50, iterations / 4),
                before: { _ in before() }, after: { _ in after() })
        }
    }
#endif
