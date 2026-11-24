import Foundation
import XCTest
@testable import LuxoClient

final class DateTimePrecisionTests: XCTestCase {
    func testInvalidJSONResponseUsesDecodeError() {
        let invalid = "2000-01-01T00:00:00.1234567890Z"
        XCTAssertThrowsError(try validateDateTime(invalid)) { error in
            XCTAssertEqual((error as? LuxoError)?.name, "DecodeError")
        }
        XCTAssertThrowsError(try dateTimeParts(invalid)) { error in
            XCTAssertEqual((error as? LuxoError)?.name, "ConfigError")
        }
        let plan = JSONParameterPlan(params: [.init(fieldID: 1, name: "date", type: "DateTime")], types: [:])!
        XCTAssertThrowsError(try LuxoJSONRequest.encode(api: "echo", params: ["date": .string(invalid)], plan: plan)) {
            error in
            XCTAssertEqual((error as? LuxoError)?.name, "ConfigError")
            XCTAssertTrue((error as? LuxoError)?.message.contains("date") == true)
        }
    }

    func testNanosecondsPreservedWithoutDateRounding() throws {
        for (input, seconds, nanos) in [
            ("1970-01-01T00:00:00.000000001Z", Int64(0), UInt64(1)),
            ("1969-12-31T23:59:59.999999999Z", -1, 999_999_999),
            ("9999-12-31T23:59:59.999999999Z", 253_402_300_799, 999_999_999),
        ] {
            var golden = Encoder()
            golden.writeSvarint(seconds)
            golden.writeVarint(nanos)
            var encoded = Encoder()
            try encoded.writeDateTime(input)
            XCTAssertEqual(encoded.data, golden.data, input)
            var decoded = Decoder(golden.data)
            XCTAssertEqual(decoded.readDateTime(), input)
            XCTAssertNil(decoded.error)
            XCTAssertEqual(decoded.remaining, 0)
        }
    }

    func testInvalidNanosAreNotNormalized() {
        for data in [Data([0]), Data([0, 128]), Data([0, 128, 148, 235, 220, 3])] {
            var decoder = Decoder(data)
            _ = decoder.readDateTime()
            XCTAssertNotNil(decoder.error)
        }
    }
}
