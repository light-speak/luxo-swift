import Foundation
import XCTest
@testable import LuxoClient

final class JSONNumberTests: XCTestCase {
    func testRequestSeparatesRoutingAndBusinessFields() throws {
        let params: [String: LuxoValue] = [
            "$api": .string("copy"), "$sub": .string("copy"), "$unsub": .int(17), "$id": .int(19),
            "$select": .string("id"), "value": .int(7),
        ]
        for subscription in [false, true] {
            let data = try LuxoJSONRequest.encode(
                api: "live", params: params, plan: nil, sequence: 1, subscription: subscription)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let route = subscription ? "$sub" : "$api"
            XCTAssertEqual(Set(body.keys), [route, "$id", "$select", "value"])
            XCTAssertEqual(body[route] as? String, "live")
            XCTAssertEqual(body["$id"] as? Int, 1)
            XCTAssertEqual(body["$select"] as? String, "id")
        }
    }

    func testLuxoJSONWritingKeepsGenericRootInsideModelsAndLists() throws {
        struct Packet: Encodable { let value: JSONValue; let values: [JSONValue] }
        for depth in 127...129 {
            var value: JSONValue = .array([])
            for _ in 1..<depth { value = .object(["v": value]) }
            let packet = Packet(value: value, values: [value])
            if depth <= 128 {
                let expected = try JSONEncoder().encode(packet)
                let actual = try LuxoJSONEncoder().encode(packet)
                XCTAssertEqual(
                    try JSONSerialization.jsonObject(with: actual) as? NSDictionary,
                    try JSONSerialization.jsonObject(with: expected) as? NSDictionary)
                XCTAssertNoThrow(try LuxoJSONEncoder().encode([value]))
            } else {
                XCTAssertThrowsError(try LuxoJSONEncoder().encode(packet))
                XCTAssertThrowsError(try LuxoJSONEncoder().encode([value]))
            }
        }
    }

    func testSchemaJSONRootsKeepTheirBudgetInRequests() throws {
        let schema = APISchema(
            id: 1,
            params: [
                .init(fieldID: 1, name: "value", type: "JSON"),
                .init(fieldID: 2, name: "values", type: "JSON", isList: true),
                .init(fieldID: 3, name: "model", type: "Model", typeName: "Packet"),
            ],
            types: [
                "Packet": [
                    "value": .init(fieldID: 1, type: "JSON"),
                    "values": .init(fieldID: 2, type: "JSON", isList: true),
                ]
            ])
        for depth in 127...129 {
            var value: JSONValue = .object([:])
            for _ in 1..<depth { value = .array([value]) }
            for raw in [LuxoValue(value), .json(value)] {
                let params: [String: LuxoValue] = [
                    "value": raw, "values": .array([raw]),
                    "model": .object(["value": raw, "values": .array([raw])]),
                ]
                if depth <= 128 {
                    let text = String(decoding: try value.jsonData(), as: UTF8.self)
                    let expected =
                        "{\"$api\":\"echo\",\"model\":{\"value\":" + text
                        + ",\"values\":[" + text + "]},\"value\":" + text + ",\"values\":[" + text + "]}"
                    XCTAssertEqual(
                        try LuxoJSONRequest.encode(api: "echo", params: params, plan: schema.jsonParameters),
                        Data(expected.utf8))
                    XCTAssertNoThrow(
                        try LuxoWebSocketProtocol.jsonCallFrame(
                            sequence: 1, api: "echo", params: params, plan: schema.jsonParameters))
                } else {
                    XCTAssertThrowsError(
                        try LuxoJSONRequest.encode(api: "echo", params: params, plan: schema.jsonParameters))
                }
            }
        }
    }

    func testJSONRootMarkerPreservesStrictTransportEqualityAndValidation() throws {
        let values: [JSONValue] = [
            .null, .bool(true), .integer(1), .number(1),
            .rawNumber(try JSONNumber("1e400")), .string("x"), .array([]),
            .array([.bool(true)]), .object([:]), .object(["v": .array([.integer(1)])]),
        ]
        for a in values {
            for b in values {
                let expected = LuxoValue(a) == LuxoValue(b)
                XCTAssertEqual(LuxoValue.json(a) == LuxoValue(b), expected)
                XCTAssertEqual(LuxoValue(a) == LuxoValue.json(b), expected)
                XCTAssertEqual(LuxoValue.json(a) == LuxoValue.json(b), expected)
            }
            XCTAssertEqual(try JSONValue(.json(a)), a)
            XCTAssertEqual(try LuxoValue.json(a).jsonData(), try LuxoValue(a).jsonData())
        }
        XCTAssertNotEqual(LuxoValue.json(.object(["a": .null])), .object(["b": .null]))
        XCTAssertNotEqual(LuxoValue.json(.object(["a": .null])), .json(.object(["b": .null])))
        XCTAssertNotEqual(LuxoValue.json(.null), .bytes(Data()))
        var deep: JSONValue = .array([])
        for _ in 1..<128 { deep = .array([deep]) }
        XCTAssertNoThrow(try JSONValue(.json(deep)))
        XCTAssertThrowsError(try JSONValue(.array([.json(deep)])))
        XCTAssertNoThrow(try LuxoValue.json(deep).foundationValue())
        deep = .array([deep])
        XCTAssertThrowsError(try LuxoValue.json(deep).jsonData())
        XCTAssertThrowsError(try LuxoValue.json(deep).foundationValue())
        XCTAssertThrowsError(try JSONValue(.json(deep)))
    }

    func testJSONRootFoundationProjectionPreservesValuesAndRejectsDeepObjects() throws {
        let value = JSONValue.object([
            "values": .array([.null, .bool(true), .integer(Int64.max), .number(1.25), .string("text")]),
            "empty": .object([:]),
        ])
        let legacy = try JSONSerialization.data(
            withJSONObject: LuxoValue(value).foundationValue(), options: .sortedKeys)
        let tagged = try JSONSerialization.data(
            withJSONObject: LuxoValue.json(value).foundationValue(), options: .sortedKeys)
        XCTAssertEqual(tagged, legacy)
        let number = try JSONNumber("1e400")
        XCTAssertEqual(try LuxoValue.json(.rawNumber(number)).foundationValue() as? JSONNumber, number)
        XCTAssertEqual(try JSONEncoder().encode(JSONValue.number(1.25)), Data("1.25".utf8))
        XCTAssertThrowsError(try JSONEncoder().encode(JSONValue.number(.nan)))
        XCTAssertThrowsError(try LuxoValue.json(.number(.infinity)).foundationValue())
        for depth in 127...129 {
            var value: JSONValue = .null
            for _ in 0..<depth { value = .object(["v": value]) }
            if depth <= 128 {
                XCTAssertNoThrow(try LuxoValue.json(value).foundationValue())
            } else {
                XCTAssertThrowsError(try LuxoValue.json(value).foundationValue())
            }
        }
    }

    func testFoundationJSONDepthIsIndependentOfModelsAndTypedLists() throws {
        struct Packet: Codable { let value: JSONValue }
        for objects in [false, true] {
            for depth in 127...129 {
                for leaf: JSONValue in [.null, .bool(true), .string("leaf"), .array([]), .object([:])] {
                    let containers = depth - (leaf == .array([]) || leaf == .object([:]) ? 1 : 0)
                    var value = leaf
                    for _ in 0..<containers { value = objects ? .object(["v": value]) : .array([value]) }
                    let leafText = String(decoding: try JSONEncoder().encode(leaf), as: UTF8.self)
                    let text =
                        String(repeating: objects ? "{\"v\":" : "[", count: containers)
                        + leafText + String(repeating: objects ? "}" : "]", count: containers)
                    let listText = "[" + text + "]"
                    let modelText = "{\"value\":" + text + "}"
                    if depth <= 128 {
                        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)), value)
                        XCTAssertEqual(try JSONDecoder().decode([JSONValue].self, from: Data(listText.utf8)), [value])
                        XCTAssertEqual(try JSONDecoder().decode(Packet.self, from: Data(modelText.utf8)).value, value)
                        XCTAssertNoThrow(try JSONEncoder().encode(value))
                        XCTAssertNoThrow(try JSONEncoder().encode([value]))
                        XCTAssertNoThrow(try JSONEncoder().encode(Packet(value: value)))
                    } else {
                        XCTAssertThrowsError(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))
                        XCTAssertThrowsError(try JSONDecoder().decode([JSONValue].self, from: Data(listText.utf8)))
                        XCTAssertThrowsError(try JSONDecoder().decode(Packet.self, from: Data(modelText.utf8)))
                        XCTAssertThrowsError(try JSONEncoder().encode(value))
                        XCTAssertThrowsError(try JSONEncoder().encode([value]))
                        XCTAssertThrowsError(try JSONEncoder().encode(Packet(value: value)))
                    }
                }
            }
        }
    }

    func testGenericJSONCountsContainersIncludingEmptyLeaves() throws {
        for objects in [false, true] {
            for depth in 127...129 {
                for leaf in ["0", "[]", "{}", "1e400"] {
                    let containers = depth - (["[]", "{}"].contains(leaf) ? 1 : 0)
                    let text =
                        String(repeating: objects ? "{\"v\":" : "[", count: containers)
                        + leaf + String(repeating: objects ? "}" : "]", count: containers)
                    let data = Data(text.utf8)
                    var value: JSONValue =
                        leaf == "[]"
                        ? .array([])
                        : leaf == "{}"
                            ? .object([:])
                            : leaf == "0" ? .integer(0) : .rawNumber(try JSONNumber(leaf))
                    for _ in 0..<containers { value = objects ? .object(["v": value]) : .array([value]) }
                    if depth <= 128 {
                        XCTAssertEqual(try JSONValue.parseBinary(data), value)
                        XCTAssertEqual(try value.jsonData(), data)
                        XCTAssertEqual(try JSONValue(LuxoValue(value)), value)
                    } else {
                        XCTAssertThrowsError(try JSONValue.parseBinary(data), "\(objects) \(depth) \(leaf)")
                        XCTAssertThrowsError(try value.jsonData())
                        XCTAssertThrowsError(try JSONValue(LuxoValue(value)))
                        XCTAssertThrowsError(try LuxoValue.encode(value))
                    }
                    for errorResponse in [false, true] {
                        let body = Data(("{\"data\":" + text + "}").utf8)
                        if depth <= 128 {
                            XCTAssertNoThrow(try JSONEnvelope.decode(body, errorResponse: errorResponse))
                        } else {
                            XCTAssertThrowsError(try JSONEnvelope.decode(body, errorResponse: errorResponse))
                        }
                    }
                }
            }
        }
    }

    func testDuplicateKeysCannotHideDeepGenericJSONSource() throws {
        let deep = String(repeating: "[", count: 128) + "[]" + String(repeating: "]", count: 128)
        for text in [deep, "{\"v\":" + deep + ",\"v\":0}"] {
            XCTAssertThrowsError(try JSONValue.parseBinary(Data(text.utf8)))
            for errorResponse in [false, true] {
                XCTAssertThrowsError(
                    try JSONEnvelope.decode(Data(("{\"data\":" + text + "}").utf8), errorResponse: errorResponse))
            }
            var encoder = Encoder()
            encoder.writeVarint(1); encoder.writeSvarint(400)
            encoder.writeVarint(2); encoder.writeString("Custom")
            encoder.writeVarint(3); encoder.writeString("failed")
            encoder.writeVarint(5); encoder.writeString(text); encoder.writeEnd()
            XCTAssertEqual(LuxoBinaryProtocol.decodeError(encoder.data, statusCode: 502).name, "ParseError")
        }
    }

    func testCheckedJSONProjectionStopsBeforeUnboundedConversion() throws {
        for objects in [false, true] {
            var value: JSONValue = .null
            for _ in 0..<1024 { value = objects ? .object(["v": value]) : .array([value]) }
            XCTAssertThrowsError(try LuxoValue.checkedJSON(value))
            XCTAssertThrowsError(try LuxoValue.encode(value))
            XCTAssertThrowsError(try value.jsonData())
            var encoder = Encoder()
            encoder.writeString("prefix")
            let prefix = encoder.data
            XCTAssertThrowsError(try encoder.writeJSON(value))
            XCTAssertEqual(encoder.data, prefix)
        }
        let valid: [JSONValue] = [
            .null, .bool(true), .integer(42), .number(1.25), .string("[{}]"),
            .rawNumber(try JSONNumber("1e400")), .array([]), .object([:]),
        ]
        for value in valid { XCTAssertEqual(try LuxoValue.checkedJSON(value), LuxoValue(value)) }
    }

    func testJSONPayloadDepthDoesNotDependOnEnvelope() throws {
        for depth in [127, 128, 129, 130] {
            for leaf in ["0", "[]", "{}"] {
                let text = String(repeating: "[", count: depth) + leaf + String(repeating: "]", count: depth)
                let payload = Data(text.utf8)
                let expected = Result { try JSONValue.parseBinary(payload) }
                for errorResponse in [false, true] {
                    for prefix in ["", #""error":"Custom","code":400,"message":"failed","#] {
                        let body = Data(("{" + prefix + "\"data\":" + text + "}").utf8)
                        let actual = Result { try JSONEnvelope.decode(body, errorResponse: errorResponse) }
                        switch (expected, actual) {
                        case (.success, .success(let envelope)):
                            XCTAssertEqual(envelope.responseData, payload)
                            XCTAssertNoThrow(try envelope.materializedFields())
                        case (.failure, .failure): break
                        default:
                            XCTFail(
                                "payload/envelope depth mismatch: depth=\(depth) leaf=\(leaf) error=\(errorResponse)")
                        }
                    }
                }
            }
        }
    }

    func testBinaryJSONDoesNotAcceptDocumentBOM() throws {
        for text in ["null", "42", "{}", "[]", #""value""#] {
            let data = Data([0xef, 0xbb, 0xbf]) + Data(text.utf8)
            XCTAssertThrowsError(try JSONValue.parseBinary(data))
            XCTAssertEqual(try JSONValue.parse(data), try JSONValue.parse(Data(text.utf8)))
            var encoder = Encoder()
            encoder.writeVarint(1); encoder.writeSvarint(400)
            encoder.writeVarint(2); encoder.writeString("Custom")
            encoder.writeVarint(3); encoder.writeString("failed")
            encoder.writeVarint(5); encoder.writeBytes(data); encoder.writeEnd()
            XCTAssertEqual(LuxoBinaryProtocol.decodeError(encoder.data, statusCode: 502).name, "ParseError")
        }
        XCTAssertEqual(try JSONValue.parseBinary(Data("\"\u{feff}text\"".utf8)), .string("\u{feff}text"))
        let envelope = Data([0xef, 0xbb, 0xbf]) + Data(#"{"data":null}"#.utf8)
        XCTAssertTrue(try JSONEnvelope.decode(envelope).hasData)
    }

    func testPrototypeNamedErrorDataKeysSurviveBothEncodings() throws {
        let text =
            #"{"__proto__":{"marker":"value"},"constructor":{"prototype":{"marker":"value"}},"#
            + #""hasOwnProperty":false,"toJSON":"literal","n":9007199254740993,"precise":1.2300}"#
        let envelope = try JSONEnvelope.decode(
            Data(#"{"error":"Custom","code":400,"message":"failed","data":\#(text)}"#.utf8))
        var encoder = Encoder()
        encoder.writeVarint(1); encoder.writeSvarint(400)
        encoder.writeVarint(2); encoder.writeString("Custom")
        encoder.writeVarint(3); encoder.writeString("failed")
        encoder.writeVarint(5); encoder.writeString(text); encoder.writeEnd()
        let errors = [
            JSONEnvelope.decodeError(envelope, statusCode: 502),
            LuxoBinaryProtocol.decodeError(encoder.data, statusCode: 502),
        ]
        for error in errors {
            XCTAssertEqual(error.name, "Custom")
            let data = try XCTUnwrap(error.data as? [String: Any])
            XCTAssertEqual((data["__proto__"] as? [String: Any])?["marker"] as? String, "value")
            let constructor = try XCTUnwrap(data["constructor"] as? [String: Any])
            XCTAssertEqual((constructor["prototype"] as? [String: Any])?["marker"] as? String, "value")
            XCTAssertEqual(data["hasOwnProperty"] as? Bool, false)
            XCTAssertEqual(data["toJSON"] as? String, "literal")
            XCTAssertEqual(data["n"] as? Int64, 9007199254740993)
            XCTAssertEqual((data["precise"] as? JSONNumber)?.literal, "1.2300")
        }
    }

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
            "0,1", "0,\"extra\":true", "0,\"value\":1",
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
