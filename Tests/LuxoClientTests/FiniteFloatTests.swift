import Foundation
import XCTest
@testable import LuxoClient

final class FiniteFloatTests: XCTestCase {
    private func wire(_ bits: UInt64) -> Data {
        var littleEndian = bits.littleEndian
        return withUnsafeBytes(of: &littleEndian) { Data($0) }
    }

    func testReadersRejectNonFiniteFloat() {
        let invalid: [UInt64] = [
            0x7ff0000000000000, 0xfff0000000000000, 0x7ff8000000000000,
            0x7ff0000000000001, 0xfff0000000000001,
            0x7fffffffffffffff, 0xffffffffffffffff,
        ]
        for bits in invalid {
            var row = Decoder(wire(bits))
            _ = row.readFixed64()
            XCTAssertNotNil(row.error)
            for nullable in [false, true] {
                let prefix: [UInt8] = nullable ? [1, 0, 1, 1] : [1, 0, 1]
                var column = ColumnarDecoder(data: Data(prefix) + wire(bits) + Data([0]))
                XCTAssertTrue(column.nextColumn())
                if nullable {
                    XCTAssertTrue(column.readColumnFloatPtr().isEmpty)
                } else {
                    XCTAssertTrue(column.readColumnFloat().isEmpty)
                }
                XCTAssertNotNil(column.error)
            }
        }
    }

    func testFiniteFloatPreservesBits() {
        let finite: [UInt64] = [
            0, 0x8000000000000000, 1, 0x8000000000000001,
            0x000fffffffffffff, 0x0010000000000000,
            0x7fefffffffffffff, 0xffefffffffffffff,
        ]
        for bits in finite {
            var row = Decoder(wire(bits))
            XCTAssertEqual(row.readFixed64().bitPattern, bits)
            XCTAssertNil(row.error)
        }
    }
}
