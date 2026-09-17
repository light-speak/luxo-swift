import Foundation
import XCTest
@testable import LuxoClient

final class CodecMetadataTests: XCTestCase {
    func testNonemptyListsRequireColumnPayloadBeforeAllocation() {
        for count: UInt64 in [1, 128, 10_000_000] {
            for payload in [
                Data(), Data([0]), Data([1, 0]), Data([0, 1, 2, 3, 4]),
                Data([0x80, 0, 1, 2]), Data([0x80, 0x80, 0, 1]), Data([0x80, 1, 0]),
            ] {
                var decoder = ColumnarDecoder(data: unsigned(count) + Data([0]) + payload)
                XCTAssertNotNil(decoder.error)
                XCTAssertFalse(decoder.nextColumn())
            }
        }
    }

    func testEmptyListsAndNullableColumnsWithMultibyteFieldIDsRemainValid() {
        for count in [0, 1, 2] {
            for id in count == 0 ? [0] : [1, 128, 16384] {
                let payload =
                    count == 0 ? Data([0]) : unsigned(UInt64(id)) + Data(repeating: 0, count: count) + Data([0])
                var decoder = ColumnarDecoder(data: unsigned(UInt64(count)) + Data([0]) + payload)
                XCTAssertNil(decoder.error)
                if count > 0 {
                    XCTAssertTrue(decoder.nextColumn())
                    XCTAssertEqual(decoder.fieldID, id)
                    XCTAssertEqual(decoder.readColumnIntPtr(), [Int64?](repeating: nil, count: count))
                }
                XCTAssertFalse(decoder.nextColumn())
                XCTAssertNil(decoder.error)
            }
        }
    }

    func testArrayRejectsImpossibleCountsBeforeCallingTheReader() {
        for count: UInt64 in [1, 128, 1_000_000, 1_000_001, 1 << 32, UInt64.max] {
            var decoder = Decoder(unsigned(count))
            var calls = 0
            let values = decoder.readArray { decoder in
                calls += 1
                return decoder.readSvarint()
            }
            XCTAssertTrue(values.isEmpty)
            XCTAssertEqual(calls, 0, "must preflight before allocating/reading \(count) elements")
            XCTAssertNotNil(decoder.error)
        }
    }

    func testArrayAcceptsInclusiveLimitAndPreservesNextField() {
        for count in [0, 1, 128, 1_000_000] {
            var decoder = Decoder(unsigned(UInt64(count)) + Data(repeating: 0, count: count) + Data([7]))
            let values = decoder.readArray { $0.readBool() }
            XCTAssertEqual(values.count, count)
            XCTAssertFalse(values.contains(true))
            XCTAssertNil(decoder.error)
            XCTAssertEqual(decoder.nextField(), 7)
        }
    }

    func testRowAndColumnArenaLimitsAgree() {
        for size: UInt64 in [0, 1, 67_108_864, 67_108_865, 1 << 32, UInt64.max] {
            var row = Decoder(unsigned(size) + Data([0]))
            row.skipArenaHeader()
            let column = ColumnarDecoder(data: Data([0]) + unsigned(size) + Data([0]))
            XCTAssertEqual(row.error == nil, size <= 67_108_864)
            XCTAssertEqual(column.error == nil, size <= 67_108_864)
        }
    }

    func testMissingRowTerminatorCannotBecomeSuccess() {
        var decoder = Decoder(Data([0]))
        decoder.skipArenaHeader()
        XCTAssertEqual(decoder.nextField(), 0)
        XCTAssertNotNil(decoder.error)
        var valid = Decoder(Data([0, 0]))
        valid.skipArenaHeader()
        XCTAssertEqual(valid.nextField(), 0)
        XCTAssertNil(valid.error)
    }

    func testPreflightsPreserveEarlierErrors() {
        var row = Decoder(Data([0x80]))
        row.skipArenaHeader()
        let failure = row.error
        XCTAssertNotNil(failure)
        XCTAssertEqual(row.nextField(), 0)
        XCTAssertEqual(row.error, failure)
        var column = ColumnarDecoder(data: Data())
        let columnFailure = column.error
        XCTAssertTrue(column.readColumnInt().isEmpty)
        XCTAssertTrue(column.readColumnIntPtr().isEmpty)
        XCTAssertEqual(column.error, columnFailure)
    }

    func testNullableFixedWidthColumnsOnlyRequireMarkerBytesForNulls() {
        var floats = ColumnarDecoder(data: Data([3, 0, 1, 0, 0, 0, 0]))
        XCTAssertTrue(floats.nextColumn())
        XCTAssertEqual(floats.readColumnFloatPtr(), [nil, nil, nil])
        XCTAssertFalse(floats.nextColumn())
        XCTAssertNil(floats.error)
        var uuids = ColumnarDecoder(data: Data([3, 0, 1, 0, 0, 0, 0]))
        XCTAssertTrue(uuids.nextColumn())
        XCTAssertEqual(uuids.readColumnUUIDPtr(), [nil, nil, nil])
        XCTAssertFalse(uuids.nextColumn())
        XCTAssertNil(uuids.error)
    }

    func testColumnsPreflightMinimumBytesBeforeReading() {
        assertPreflight(width: 1, read: { $0.readColumnInt() })
        assertPreflight(width: 8, read: { $0.readColumnFloat() })
        assertPreflight(width: 1, read: { $0.readColumnString() })
        assertPreflight(width: 1, read: { $0.readColumnBool() })
        assertPreflight(width: 16, read: { $0.readColumnUUID() })
        assertPreflight(width: 1, read: { $0.readColumnBytes() })
        assertPreflight(width: 1, read: { $0.readColumnDateTime() })
        assertPreflight(width: 1, read: { $0.readColumnIntPtr() })
        assertPreflight(width: 1, read: { $0.readColumnFloatPtr() })
        assertPreflight(width: 1, read: { $0.readColumnStringPtr() })
        assertPreflight(width: 1, read: { $0.readColumnBoolPtr() })
        assertPreflight(width: 1, read: { $0.readColumnUUIDPtr() })
        assertPreflight(width: 1, read: { $0.readColumnBytesPtr() })
        assertPreflight(width: 1, read: { $0.readColumnDateTimePtr() })
    }

    private func assertPreflight<Value>(
        width: Int, read: (inout ColumnarDecoder) -> [Value],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let payload = Data([3, 0, 1]) + Data(repeating: 0, count: 3 * width - 1)
        var decoder = ColumnarDecoder(data: payload)
        XCTAssertEqual(decoder.nextColumn(), width > 1, file: file, line: line)
        let position = decoder.offset
        XCTAssertTrue(read(&decoder).isEmpty, file: file, line: line)
        XCTAssertNotNil(decoder.error, file: file, line: line)
        XCTAssertEqual(decoder.offset, position, "must reject before consuming the column", file: file, line: line)
    }

    // Independent fixture writer; it must not share the production varint encoder.
    private func unsigned(_ value: UInt64) -> Data {
        var value = value
        var bytes = Data()
        repeat {
            let byte = UInt8(value & 127)
            value >>= 7
            bytes.append(byte | (value == 0 ? 0 : 128))
        } while value != 0
        return bytes
    }
}
