import Foundation
import XCTest
@testable import LuxoClient

final class JSONNumberTests: XCTestCase {
    func testLegacyUTF8KeepsBOMContentAndRejectsMalformedBytes() throws {
        for text in ["", "東京", "\u{feff}", "\u{feff}\u{feff}text", "\u{fffd}"] {
            try Data(text.utf8).withUnsafeBytes { raw in
                let reader = JSONReader(bytes: raw.bindMemory(to: UInt8.self))
                XCTAssertEqual(try reader.legacyUTF8(0..<raw.count), text)
            }
        }
        try Data([0xff]).withUnsafeBytes { raw in
            XCTAssertThrowsError(try JSONReader(bytes: raw.bindMemory(to: UInt8.self)).legacyUTF8(0..<1))
        }
    }

    func testDeterministicJSONRoundTripsAndDepthLimit() throws {
        var state: UInt64 = 0x531f2d00
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1; return state }
        func value(_ depth: Int) -> LuxoValue {
            switch next() % (depth < 4 ? 7 : 5) {
            case 0: return .null
            case 1: return .bool(next() % 2 == 0)
            case 2: return .int(Int64(bitPattern: next()))
            case 3: return .string("東京\u{feff}e\u{301}\n\t\"\\" + String(next()))
            case 4: return .jsonNumber(JSONNumber(validated: "-0.12345678901234567890123456789e-099"))
            case 5: return .array((0..<3).map { _ in value(depth + 1) })
            default: return .object(["a": value(depth + 1), "b": value(depth + 1)])
            }
        }
        for _ in 0..<500 {
            let original = value(0)
            let data = try original.jsonData()
            XCTAssertEqual(try LuxoValue.decodeJSONData(data), original)
            XCTAssertEqual(try LuxoValue.decodeJSONData(data).jsonData(), data)
        }
        var nested: LuxoValue = .int(0)
        for _ in 0..<128 { nested = .array([nested]) }
        XCTAssertNoThrow(try nested.jsonData())
        XCTAssertThrowsError(try LuxoValue.array([nested]).jsonData())
    }

    func testFoundationGenericNumbersFailClosed() throws {
        for text in ["42", "1.0", "1e400", "{\"n\":-0}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))
        }
        XCTAssertThrowsError(try JSONEncoder().encode(JSONValue.rawNumber(JSONNumber("1.0"))))
    }
    func testCustomEncodablePreservesRawNumbersWithoutAJSONRoundTrip() throws {
        struct Input: Codable, Sendable { let value: JSONValue; let id: UInt64; let bytes: Data }
        let value = try JSONValue.parse(Data(#"{"n":1E+03,"small":1e-400}"#.utf8))
        let input = Input(value: value, id: UInt64.max, bytes: Data([0, 1]))
        let encoded = try LuxoJSONEncoder().encode(input)
        XCTAssertEqual(
            String(decoding: encoded, as: UTF8.self),
            #"{"bytes":"AAE=","id":18446744073709551615,"value":{"n":1E+03,"small":1e-400}}"#)
        let decoded = try LuxoJSONDecoder().decode(Input.self, from: encoded)
        XCTAssertEqual(decoded.value, value)
        XCTAssertEqual(decoded.id, UInt64.max)
        XCTAssertEqual(decoded.bytes, input.bytes)
        XCTAssertEqual(try LuxoValue.encode(input).jsonData(), encoded)
    }
    func testTypedDecodingDoesNotConvertGenericNumbers() throws {
        struct Response: Decodable {
            let id: Int64
            let rate: Double
            let json: JSONValue
            let missing: Selected<String>
            let note: Selected<String?>
        }
        let text = #"{"id":9223372036854775807,"rate":1.25,"json":{"n":1e400},"note":null}"#
        let response = try LuxoJSONDecoder().decode(Response.self, from: Data(text.utf8))
        XCTAssertEqual(response.id, Int64.max)
        XCTAssertEqual(response.rate, 1.25)
        XCTAssertEqual(response.json, .object(["n": .rawNumber(try JSONNumber("1e400"))]))
        XCTAssertThrowsError(try response.missing.requireValue())
        XCTAssertNil(try response.note.requireValue())
        for token in ["1.0", "1e0", "9223372036854775808", "true", "\"1\""] {
            XCTAssertThrowsError(try LuxoJSONDecoder().decode(Int64.self, from: Data(token.utf8)), token)
        }
        for token in ["1e400", "1e-400"] {
            XCTAssertThrowsError(try LuxoJSONDecoder().decode(Double.self, from: Data(token.utf8)), token)
        }
    }

    func testErrorDataPreservesNumbersInBothModes() throws {
        let data = Data(#"{"n":1e400,"small":1e-400,"zero":-0}"#.utf8)
        var encoder = Encoder()
        encoder.writeVarint(1); encoder.writeSvarint(400)
        encoder.writeVarint(2); encoder.writeString("RemoteError")
        encoder.writeVarint(3); encoder.writeString("failed")
        encoder.writeVarint(5); encoder.writeBytes(data); encoder.writeEnd()
        let binaryError = LuxoBinaryProtocol.decodeError(encoder.data, statusCode: 400)
        XCTAssertEqual(binaryError.name, "RemoteError")
        let fields = try XCTUnwrap(binaryError.data as? [String: Any])
        XCTAssertEqual((fields["n"] as? JSONNumber)?.literal, "1e400")
        XCTAssertEqual((fields["small"] as? JSONNumber)?.literal, "1e-400")
        XCTAssertEqual((fields["zero"] as? JSONNumber)?.literal, "-0")
    }

    func testRawNumberConstructionAndExplicitConversions() throws {
        for invalid in [
            "", " 1", "1 ", "+1", "01", "-01", "1.", ".1", "1e", "1e+", "NaN", "Infinity", "null", "true", "\"1\"",
            "[]", "{}", "1,2", "١", "-", "--1",
        ] {
            XCTAssertThrowsError(try JSONNumber(invalid), invalid)
        }
        for token in ["0", "-0", "9223372036854775807", "-9223372036854775808"] {
            XCTAssertEqual(try JSONNumber(token).toInt64(), Int64(token))
        }
        for token in ["1.0", "1e0", "9223372036854775808", "-9223372036854775809"] {
            XCTAssertThrowsError(try JSONNumber(token).toInt64(), token)
        }
        for token in ["1e400", "-1e400", "1e-400", "-1e-400"] {
            XCTAssertThrowsError(try JSONNumber(token).toDouble(), token)
        }
        for token in ["1.25", "0.12345678901234567890123456789", "-0", "0e99999", "-0e-99999", "5e-324"] {
            XCTAssertEqual(try JSONNumber(token).toDouble().bitPattern, Double(token)?.bitPattern, token)
        }
    }

    func testStringsAndMalformedInput() throws {
        let strings = ["", "東京", "\u{feff}\u{fffd}", "\u{1f600}", "\"/\\\n\r\t\u{8}\u{c}\u{0}\u{1f}", "e\u{301}"]
        for string in strings {
            let value = LuxoValue.string(string)
            let encoded = try value.jsonData()
            XCTAssertEqual(try LuxoValue.decodeJSONData(encoded), value)
            XCTAssertEqual(try JSONDecoder().decode(String.self, from: encoded), string)
        }
        for (text, expected) in [
            (#""\ud83d\ude00""#, "\u{1f600}"), (#""\u0041\/\u0000""#, "A/\u{0}"), (#""\u00AF""#, "¯"),
        ] {
            XCTAssertEqual(try LuxoValue.decodeJSONData(Data(text.utf8)), .string(expected))
        }
        for text in [
            "", "[1,]", "{\"a\":1,}", "{a:1}", "{\"a\" 1}", "[1 2]", "null x", "TRUE", "nul", "--0", "1e", "01",
            "\"\n\"", "\"\\x\"", "\"\\u000g\"", "\"\\u12\"", "\"\\ud800\"", "\"\\udc00\"", "\"\\ud800\\u0041\"",
            "\"unterminated", "\"trailing\\", "\"escaped\\n", "\"escaped\\n\n\"", #"{"a":1 "b":2}"#,
        ] {
            XCTAssertThrowsError(try LuxoValue.decodeJSONData(Data(text.utf8)), text)
        }
        for bytes: [UInt8] in [
            [34, 0xff, 34], [34, 0xc0, 0x80, 34], [34, 0xed, 0xa0, 0x80, 34], [34, 0xf4, 0x90, 0x80, 0x80, 34],
            [34, 92, 110, 0xff, 34],
        ] {
            XCTAssertThrowsError(try LuxoValue.decodeJSONData(Data(bytes)))
        }
        XCTAssertEqual(try LuxoValue.decodeJSONData(Data([0xef, 0xbb, 0xbf]) + Data(" \n42\t\r".utf8)), .int(42))
        XCTAssertThrowsError(try LuxoValue.decodeJSONData(Data([0xef, 0xbb, 0xbf, 0xef, 0xbb, 0xbf]) + Data("0".utf8)))
        for count in [128, 129] {
            let data = Data((String(repeating: "[", count: count) + "0" + String(repeating: "]", count: count)).utf8)
            if count == 128 {
                XCTAssertNoThrow(try LuxoValue.decodeJSONData(data))
            } else {
                XCTAssertThrowsError(try LuxoValue.decodeJSONData(data))
            }
        }
    }

    func testJSONArrayInclusiveElementLimit() throws {
        let contents = String(repeating: "0,", count: 999_999) + "0"
        let allowed = try LuxoValue.decodeJSONData(Data(("[" + contents + "]").utf8))
        guard case .array(let values) = allowed else { return XCTFail("expected array") }
        XCTAssertEqual(values.count, 1_000_000)
        XCTAssertThrowsError(try LuxoValue.decodeJSONData(Data(("[" + contents + ",0]").utf8)))
    }

    func testRawNumbersInJSONAndBinaryRequests() throws {
        let value = try LuxoValue.decodeJSONData(Data(#"{"n":1E+003,"v":[1e400,1e-400,-0]}"#.utf8))
        let schema = APISchema(id: 1, params: [.init(fieldID: 1, name: "value", type: "JSON")])
        let request = try LuxoJSONRequest.encode(api: "echo", params: ["value": value], plan: schema.jsonParameters)
        XCTAssertEqual(
            String(decoding: request, as: UTF8.self), #"{"$api":"echo","value":{"n":1E+003,"v":[1e400,1e-400,-0]}}"#)
        let binary = try LuxoBinaryProtocol.encodeRequest(schema: schema, params: ["value": value])
        XCTAssertTrue(binary.range(of: try value.jsonData()) != nil)
    }

    func testTransportValuesPreserveEveryNumberToken() throws {
        struct Fixture: Decodable { let jsonNumberTokens: [String] }
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "protocol-v1", withExtension: "json", subdirectory: "Fixtures"))
        let tokens = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).jsonNumberTokens
        for token in tokens {
            for text in [token, "{\"value\":[\(token),null,{\"n\":\(token)}]}"] {
                let data = Data(text.utf8)
                do {
                    let value = try LuxoValue.decodeJSONData(data)
                    XCTAssertEqual(try value.jsonData(), data, text)
                } catch { XCTFail("\(text): \(error)") }
            }
        }
    }
}
