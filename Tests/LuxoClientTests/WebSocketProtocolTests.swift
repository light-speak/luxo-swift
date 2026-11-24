import Foundation
import XCTest
@testable import LuxoClient

final class WebSocketProtocolTests: XCTestCase {
    private func parsedObject(_ text: String) throws -> [String: LuxoValue]? {
        guard case .object(let values) = try LuxoValue.decodeJSONData(Data(text.utf8)) else { return nil }
        return values
    }
    func testParsedRequestIDRejectsNegativeZeroWithoutRejectingZero() throws {
        for token in ["-0", "-0.0", "0e0", "true", "18446744073709551616"] {
            let value = try LuxoValue.decodeJSONData(Data(token.utf8))
            XCTAssertNil(LuxoWebSocketProtocol.jsonRequestID(value: value), token)
        }
        for token in ["0", "1", "18446744073709551615"] {
            let value = try LuxoValue.decodeJSONData(Data(token.utf8))
            XCTAssertEqual(LuxoWebSocketProtocol.jsonRequestID(value: value), UInt64(token))
        }
    }
    func testJSONCallFrameKeepsUnsignedMetadataSeparateFromSignedParameters() throws {
        let params: [String: LuxoValue] = [
            "$api": .float(.nan), "$id": .float(.infinity),
            "$select": .string("id,name"), "id": .int(Int64.min),
            "nested": .object(["values": .array([.int(Int64.max), .null, .bytes(Data([42]))])]),
        ]
        let data = try LuxoWebSocketProtocol.jsonCallFrame(sequence: UInt64.max, api: "getUser", params: params)
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"{"$api":"getUser","$id":18446744073709551615,"$select":"id,name","id":-9223372036854775808,"nested":{"values":[9223372036854775807,null,"Kg=="]}}"#
        )
        XCTAssertEqual(
            try LuxoWebSocketProtocol.jsonCallFrame(sequence: 0, api: "count", params: nil),
            Data(#"{"$api":"count","$id":0}"#.utf8)
        )
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(
                try LuxoWebSocketProtocol.jsonCallFrame(
                    sequence: 1, api: "count", params: ["ratios": .array([.float(value)])]
                )
            ) { error in
                XCTAssertEqual((error as? LuxoError)?.name, "EncodingError")
            }
        }
    }

    func testJSONRequestIDPreservesUnsignedRange() throws {
        for value in [UInt64(0), 1, 253, 9_007_199_254_740_993, UInt64(Int64.max), UInt64.max] {
            let json = try XCTUnwrap(
                parsedObject("{\"$id\":\(value)}")
            )
            XCTAssertEqual(LuxoWebSocketProtocol.jsonRequestID(value: json["$id"]), value)
        }
        XCTAssertNil(LuxoWebSocketProtocol.jsonRequestID(value: nil))
        XCTAssertNil(LuxoWebSocketProtocol.jsonRequestID(value: .int(-1)))
    }

    func testBinaryFramePreservesUnsignedRangeAndPayload() throws {
        for type in [UInt64(2), 3, 0x12, 0x13, 0x14] {
            var encoder = Encoder()
            encoder.writeVarint(type)
            encoder.writeVarint(UInt64.max)
            encoder.writeRawBytes(Data([42]))
            let frame = try XCTUnwrap(LuxoWebSocketProtocol.decodeBinaryFrame(encoder.data))
            XCTAssertEqual(frame.type, type)
            XCTAssertEqual(frame.id, UInt64.max)
            XCTAssertEqual(frame.payload, Data([42]))
        }
        XCTAssertNil(LuxoWebSocketProtocol.decodeBinaryFrame(Data([1, 1])))
        XCTAssertNil(LuxoWebSocketProtocol.decodeBinaryFrame(Data([255, 1])))
    }

    func testJSONRequestIDRejectsNonIntegerStorage() throws {
        let tokens = [
            "true", "false", "null", "\"1\"", "[]", "{}", "1.5", "1.0", "1e0", "0.0", "0e0",
            "-1", "-9223372036854775808", "18446744073709551616", "18446744073709551617",
            "1.0000000000000001", "9007199254740993.5",
        ]
        for token in tokens {
            let json = try XCTUnwrap(
                parsedObject("{\"$id\":\(token)}")
            )
            XCTAssertNil(LuxoWebSocketProtocol.jsonRequestID(value: json["$id"]), token)
        }
    }

    func testJSONRequestIDPreservesIntegerStorageBoundaries() throws {
        let boundaries: [UInt64] = [
            0, 127, 128, 255, 256, 32_767, 32_768, 65_535, 65_536, 2_147_483_647, 2_147_483_648,
            4_294_967_295, 4_294_967_296, 9_007_199_254_740_991, 9_007_199_254_740_992,
            9_007_199_254_740_993, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max - 1, UInt64.max,
        ]
        for value in boundaries {
            let json = try XCTUnwrap(
                parsedObject("{\"$id\":\(value)}")
            )
            XCTAssertEqual(LuxoWebSocketProtocol.jsonRequestID(value: json["$id"]), value)
        }
    }

    func testSubscriptionAcknowledgementRequiresBooleanTrue() throws {
        for token in ["0", "1", "1.0", "\"true\"", "null", "false"] {
            let json = try XCTUnwrap(
                parsedObject("{\"$sub\":1,\"ok\":\(token)}")
            )
            XCTAssertNil(LuxoWebSocketProtocol.decodeJSONSubscriptionAcknowledgement(values: json), token)
        }
    }

    func testSuccessfulBinaryAcknowledgementRejectsTrailingPayload() {
        let frame = LuxoWebSocketProtocol.decodeBinaryFrame(Data([0x13, 1, 42]))
        let acknowledgement = frame.flatMap(LuxoWebSocketProtocol.subscriptionAcknowledgement)
        XCTAssertEqual(acknowledgement?.id, 1)
        XCTAssertEqual(acknowledgement?.error?.name, "ParseError")
    }
}
