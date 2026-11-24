import Foundation
import XCTest
@testable import LuxoClient

final class JSONEnvelopeTests: XCTestCase {
    func testTerminalMarkerTracksOnlyTopLevelMetadata() throws {
        for text in [#"{}"#, #"{"data":{"$end":1}}"#, #"{"extra":{"$end":1},"$stream":1}"#] {
            XCTAssertFalse(try JSONEnvelope.decode(Data(text.utf8)).hasTerminalMetadata)
        }
        for text in [
            #"{"$end":1,"ok":true}"#, #"{"ok":true,"\u0024end":18446744073709551615}"#,
            #"{"$end":null}"#, #"{"$stream":1,"$end":1}"#,
        ] {
            XCTAssertTrue(try JSONEnvelope.decode(Data(text.utf8)).hasTerminalMetadata)
        }
    }

    func testStringSegmentScanMatchesScalarBoundariesAtEveryAlignment() {
        for alignment in 0..<32 {
            for length in [0, 1, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 129] {
                for marker in UInt8.min...UInt8.max {
                    let input = Array(repeating: UInt8(97), count: alignment + length) + [marker, 97]
                    input.withUnsafeBufferPointer { buffer in
                        for count in [alignment + length, input.count] {
                            let bounded = UnsafeBufferPointer(start: buffer.baseAddress, count: count)
                            var reader = JSONReader(bytes: bounded, offset: alignment)
                            reader.advanceStringSegment()
                            let expected =
                                marker < 32 || marker == 34 || marker == 92
                                ? alignment + length : count
                            XCTAssertEqual(reader.offset, min(expected, count))
                        }
                    }
                }
            }
        }
    }

    func testStringMarkersUTF8AndEscapesAcrossWordBoundaries() throws {
        for length in 0...65 {
            let prefix = String(repeating: "a", count: length)
            for suffix in ["", "東京", #"\"quoted\""#, #"\ud83d\ude00"#, #"\n\t\/\\"#] {
                let value = Data("\"\(prefix)\(suffix)\"".utf8)
                let envelope = try JSONEnvelope.decode(Data(#"{"data":"#.utf8) + value + Data("}".utf8))
                XCTAssertEqual(envelope.responseData, value)
                XCTAssertEqual(try JSONReader.decode(XCTUnwrap(envelope.responseData)), try JSONReader.decode(value))
            }
            for bad: [UInt8] in [[0], [31], [0xff], [0xc2], [0xed, 0xa0, 0x80], Array(#"\ud800"#.utf8)] {
                let value = Data("\"\(prefix)".utf8) + Data(bad) + Data("\"".utf8)
                XCTAssertThrowsError(try JSONReader.decode(value))
                XCTAssertThrowsError(try JSONEnvelope.decode(Data(#"{"data":"#.utf8) + value + Data("}".utf8)))
            }
        }
    }

    func testStringSegmentScanMatchesArbitraryBytesAndEmptyPointer() {
        var empty = JSONReader(bytes: UnsafeBufferPointer(start: nil, count: 0))
        empty.advanceStringSegment()
        XCTAssertEqual(empty.offset, 0)
        var state: UInt64 = 0x531f2d00
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1; return state }
        for _ in 0..<10_000 {
            let count = Int(next() % 512)
            let bytes = (0..<count).map { _ in UInt8(truncatingIfNeeded: next() >> 32) }
            let start = Int(next() % UInt64(count + 1))
            let end = bytes[start...].firstIndex { $0 < 32 || $0 == 34 || $0 == 92 } ?? count
            bytes.withUnsafeBufferPointer { buffer in
                var reader = JSONReader(bytes: buffer, offset: start)
                reader.advanceStringSegment()
                XCTAssertEqual(reader.offset, end)
            }
        }
    }

    func testLegacyUTF8ValidationRejectsWithoutReplacement() throws {
        for bytes in [Array("東京\u{feff}abc\u{10ffff}".utf8), [], [0xff], [0xc0, 0x80], [0xed, 0xa0, 0x80], [0xc2]] {
            try bytes.withUnsafeBufferPointer { buffer in
                let reader = JSONReader(bytes: buffer)
                if String(bytes: bytes, encoding: .utf8) != nil {
                    XCTAssertNoThrow(try reader.validateLegacyUTF8(0..<buffer.count))
                } else {
                    XCTAssertThrowsError(try reader.validateLegacyUTF8(0..<buffer.count))
                }
            }
        }
    }

    private var recursiveSchema: LuxoJSONReadSchema {
        .model(
            "Node",
            types: [
                "Node": [
                    "child": .init(fieldID: 1, typeName: "Node", type: "Model"),
                    "value": .init(fieldID: 2, type: "JSON"),
                ]
            ])
    }

    func testSchemaSkipMatchesValueReaderAcrossContainerShapes() throws {
        let schemas: [LuxoJSONReadSchema] = [
            .json, .list(.json), .dictionary(.json), .page(.json), recursiveSchema,
            [JSONValue].luxoJSONSchema, [String: JSONValue].luxoJSONSchema,
            Page<JSONValue>.luxoJSONSchema, Cursor<JSONValue>.luxoJSONSchema,
        ]
        for schema in schemas {
            for value in [
                "{}", "[]", "null", "1", "true", "\"text\"", "{\"items\":[{},[]],\"child\":null,\"value\":[]}",
                "[{\"a\":1},null]",
            ] {
                let envelope = try JSONEnvelope.decode(Data("{\"data\":\(value)}".utf8), schema: schema)
                XCTAssertEqual(envelope.responseData, Data(value.utf8))
                XCTAssertNil(envelope.fields["data"])
            }
        }
        let json = String(repeating: "[", count: 129) + "null" + String(repeating: "]", count: 129)
        XCTAssertThrowsError(
            try JSONEnvelope.decode(Data("{\"$id\":1,\"data\":\(json)}".utf8), resolvePayload: { _ in .generic }))
        let elements = String(repeating: "0,", count: 1_000_000) + "0"
        XCTAssertThrowsError(try JSONEnvelope.decode(Data("{\"data\":[\(elements)]}".utf8), schema: .list(.json)))
    }

    func testSchemaPayloadLimitsAndLateErrorsValidateEveryDuplicate() throws {
        let json = String(repeating: "[", count: 128) + "null" + String(repeating: "]", count: 128)
        let payload = "{\"value\":\(json)}"
        let typed = try JSONEnvelope.decode(Data("{\"data\":\(payload)}".utf8), schema: recursiveSchema)
        XCTAssertEqual(JSONEnvelope.decodeError(typed, statusCode: 400).name, "ParseError")
        let error = "\"error\":\"Rejected\",\"code\":400,\"message\":\"no\""
        for fields in ["\"data\":\(payload)", "\"data\":null,\"data\":\(payload)"] {
            let envelope = try JSONEnvelope.decode(Data("{\(fields)}".utf8), schema: recursiveSchema)
            XCTAssertEqual(envelope.responseData, Data(payload.utf8))
            XCTAssertNil(envelope.fields["data"])
        }
        for fields in [
            "\"data\":\(payload),\(error)", "\"data\":\(payload),\"data\":null,\(error)",
            "\(error),\"data\":\(payload)",
        ] {
            XCTAssertThrowsError(try JSONEnvelope.decode(Data("{\(fields)}".utf8), schema: recursiveSchema))
        }
        let sixtyFive = String(repeating: "{\"child\":", count: 64) + "{}" + String(repeating: "}", count: 64)
        XCTAssertThrowsError(
            try JSONEnvelope.decode(Data("{\"data\":\(sixtyFive),\"data\":null}".utf8), schema: recursiveSchema))
        for fields in [
            "\"data\":\(sixtyFive),\(error)", "\(error),\"data\":\(sixtyFive)",
            "\"data\":\(sixtyFive),\"data\":null,\(error)",
        ] {
            let envelope = try JSONEnvelope.decode(Data("{\(fields)}".utf8), schema: recursiveSchema)
            XCTAssertEqual(JSONEnvelope.decodeError(envelope, statusCode: 200).name, "Rejected")
        }
        XCTAssertNoThrow(
            try JSONEnvelope.decode(
                Data("{\"data\":\(sixtyFive),\(error)}".utf8), errorResponse: true, schema: recursiveSchema))
    }

    func testDeferredPayloadUsesFinalRouteAndChecksDiscardedDuplicates() throws {
        let json = String(repeating: "[", count: 128) + "null" + String(repeating: "]", count: 128)
        let payload = "[\(json)]"
        for fields in ["\"data\":\(payload),\"$id\":2", "\"$id\":1,\"data\":\(payload),\"$id\":2"] {
            let envelope = try JSONEnvelope.decode(
                Data("{\(fields)}".utf8),
                resolvePayload: { fields in
                    fields["$id"] == .int(2) ? .schema(.list(.json)) : .generic
                })
            XCTAssertEqual(envelope.responseData, Data(payload.utf8))
            XCTAssertNil(envelope.fields["data"])
        }
        for fields in ["\"data\":[\(payload)],\"data\":null", "\"data\":null,\"data\":[\(payload)]"] {
            XCTAssertThrowsError(
                try JSONEnvelope.decode(Data("{\(fields)}".utf8), resolvePayload: { _ in .schema(.list(.json)) }))
        }
        for index in 0..<3 {
            var values = ["null", "null", "null"]
            values[index] = "[\(payload)]"
            let fields = values.map { "\"data\":\($0)" }.joined(separator: ",")
            XCTAssertThrowsError(
                try JSONEnvelope.decode(
                    Data("{\(fields),\"$id\":1}".utf8), resolvePayload: { _ in .schema(.list(.json)) }))
        }
        let repeated = Data("{\"data\":null,\"data\":[],\"data\":\(payload),\"$id\":1}".utf8)
        XCTAssertEqual(
            try JSONEnvelope.decode(repeated, resolvePayload: { _ in .schema(.list(.json)) }).responseData,
            Data(payload.utf8))
        for prefix in ["", "\"error\":\"Rejected\","] {
            XCTAssertThrowsError(
                try JSONEnvelope.decode(
                    Data("{\(prefix)\"data\":\(payload),\"error\":null}".utf8),
                    resolvePayload: { _ in .schema(.list(.json)) }))
        }
    }

    func testDiscardedPayloadStackBoundariesAndReuse() throws {
        for depth in [1, 126, 127, 128, 129, 5000] {
            for leaf in ["[1,{\"k\":2},3]", "{}", "[]"] {
                let nested = String(repeating: "[", count: depth) + leaf + String(repeating: "]", count: depth)
                let payload = "{\"first\":\(nested),\"second\":\(nested)}"
                let result = try JSONEnvelope.decode(
                    Data("{\"data\":\(payload)}".utf8), resolvePayload: { _ in .discarded })
                XCTAssertTrue(result.discardedPayload)
            }
            let malformed = String(repeating: "[", count: depth) + "[1,]" + String(repeating: "]", count: depth)
            XCTAssertThrowsError(
                try JSONEnvelope.decode(Data("{\"data\":\(malformed)}".utf8), resolvePayload: { _ in .discarded }))
        }
    }

    func testDeferredAndDiscardedPayloadGrammarMatchesStrictReader() throws {
        for value in [#""東京\ud83d\ude00""#, #""\uFEFF""#, #""escaped\\\"quote""#] {
            let document = Data("{\"data\":\(value)}".utf8)
            XCTAssertEqual(
                try JSONEnvelope.decode(document, resolvePayload: { _ in .generic }).responseData, Data(value.utf8))
        }
        for text in [#"{"data":{"v":"escape\x"#, #"{"data":"escape\x"#] {
            XCTAssertThrowsError(try JSONEnvelope.decode(Data(text.utf8), resolvePayload: { _ in .generic }))
        }
        let payload = #"[{"key":"東京\ud83d\ude00\n[]{}","value":-1.25e+2},null,true,false]"#
        let bytes = Data(payload.utf8)
        for index in bytes.indices {
            for byte: UInt8 in [0, 34, 44, 58, 91, 93, 123, 125, 255] {
                var changed = bytes; changed[index] = byte
                let expected = (try? JSONReader.decode(changed)) != nil
                let document = Data("{\"data\":".utf8) + changed + Data("}".utf8)
                for policy in [JSONPayloadValidation.generic, .discarded, .schema(.list(.json))] {
                    let result = try? JSONEnvelope.decode(document, resolvePayload: { _ in policy })
                    XCTAssertEqual(result != nil, expected, "index=\(index) byte=\(byte)")
                }
            }
        }
        for depth in [129, 5000] {
            let document = Data(
                ("{\"data\":" + String(repeating: "[", count: depth) + "null" + String(repeating: "]", count: depth)
                    + "}").utf8)
            XCTAssertTrue(try JSONEnvelope.decode(document, resolvePayload: { _ in .discarded }).discardedPayload)
            XCTAssertThrowsError(try JSONEnvelope.decode(document, resolvePayload: { _ in .generic }))
        }
        let values = String(repeating: "0,", count: 999_999) + "0"
        XCTAssertNoThrow(
            try JSONEnvelope.decode(Data("{\"data\":[\(values)]}".utf8), resolvePayload: { _ in .discarded }))
        XCTAssertThrowsError(
            try JSONEnvelope.decode(Data("{\"data\":[\(values),0]}".utf8), resolvePayload: { _ in .discarded }))
        for value in ["[", "{", "[}", "{]", "[1,]", "{\"a\":1,}", "[1 2]", "{\"a\" 1}", "{\"a\":1 \"b\":2}"] {
            XCTAssertThrowsError(
                try JSONEnvelope.decode(Data("{\"data\":\(value)}".utf8), resolvePayload: { _ in .discarded }))
        }
    }

    func testPreservesPayloadAndOnlyMaterializesMetadata() throws {
        let payload = #"{ "z":1E+003, "z":9007199254740993, "a":"\u6771\u4eac", "zero":-0 }"#
        let text = "{\"extra\":[{\"huge\":1e400}],\"data\": \(payload),\"$id\":18446744073709551615}"
        let envelope = try JSONEnvelope.decode(Data(text.utf8))
        XCTAssertEqual(envelope.responseData, Data(payload.utf8))
        XCTAssertNil(envelope.fields["data"])
        XCTAssertNil(envelope.fields["extra"])
        XCTAssertEqual(LuxoWebSocketProtocol.jsonRequestID(value: envelope.fields["$id"]), .max)
        XCTAssertEqual(
            try JSONReader.decode(XCTUnwrap(envelope.responseData)), try JSONReader.decode(Data(payload.utf8)))
    }

    func testKnownErrorsMaterializePayloadOnceRegardlessOfFieldOrder() throws {
        let payload = #"{"number":0.1234567890123456789,"zero":-0}"#
        for prefix in ["", #""error":"Rejected","code":400,"message":"bad","#] {
            for known in [false, true] {
                let envelope = try JSONEnvelope.decode(
                    Data("{\(prefix)\"data\":\(payload)}".utf8), errorResponse: known)
                XCTAssertEqual(envelope.responseData, Data(payload.utf8))
                XCTAssertEqual(envelope.fields["data"] != nil, known || !prefix.isEmpty)
                XCTAssertEqual(try envelope.materializedFields()["data"], try JSONReader.decode(Data(payload.utf8)))
            }
        }
        let duplicate = try JSONEnvelope.decode(Data(#"{"data":0,"error":"Rejected","data":-0,"data":1E+003}"#.utf8))
        XCTAssertEqual(duplicate.responseData, Data("1E+003".utf8))
        XCTAssertEqual(try duplicate.materializedFields()["data"], .jsonNumber(try JSONNumber("1E+003")))
    }

    func testPayloadKindsBOMAndNonZeroDataIndex() throws {
        for payload in ["null", "true", "false", "[]", "{}", "-0", "1.20e+099", #""\uFEFF東京\n""#, "[1, null]"] {
            let document = Data([0xef, 0xbb, 0xbf]) + Data(" \t{\"d\\u0061ta\": \(payload) }\r\n".utf8)
            let prefixed = Data([0, 1, 2]) + document
            XCTAssertEqual(try JSONEnvelope.decode(prefixed.dropFirst(3)).responseData, Data(payload.utf8))
        }
        XCTAssertNil(try JSONEnvelope.decode(Data("{}".utf8)).responseData)
        XCTAssertEqual(try JSONEnvelope.decode(Data(#"{"data":null}"#.utf8)).responseData, Data("null".utf8))
        let duplicate = try JSONEnvelope.decode(Data(#"{"data":[1],"data": 1E+003,"$id":1,"$id":2}"#.utf8))
        XCTAssertEqual(duplicate.responseData, Data("1E+003".utf8))
        XCTAssertEqual(duplicate.fields["$id"], .int(2))
    }

    func testErrorsDecodeDataWithoutRewritingItsNumbers() throws {
        let payload = #"{"big":123456789012345678901234567890,"decimal":0.1234567890123456789,"zero":-0}"#
        let text =
            "{\"data\":\(payload),\"error\":\"Rejected\",\"code\":422,\"message\":\"failed\",\"traceId\":\"trace\",\"cause\":null}"
        let error = JSONEnvelope.decodeError(try JSONEnvelope.decode(Data(text.utf8)), statusCode: 500)
        XCTAssertEqual(error.code, 422)
        XCTAssertEqual(error.name, "Rejected")
        XCTAssertEqual(error.traceId, "trace")
        XCTAssertNil(error.cause)
        let data = try XCTUnwrap(error.data as? [String: Any])
        XCTAssertEqual((data["big"] as? JSONNumber)?.literal, "123456789012345678901234567890")
        XCTAssertEqual((data["decimal"] as? JSONNumber)?.literal, "0.1234567890123456789")
        XCTAssertEqual((data["zero"] as? JSONNumber)?.literal, "-0")
        for text in [#"{"code":true,"error":"bad","message":"bad"}"#, #"{"error":"bad","data":null}"#] {
            let error = JSONEnvelope.decodeError(try JSONEnvelope.decode(Data(text.utf8)), statusCode: 400)
            XCTAssertEqual(error.name, "ParseError")
        }
    }

    func testRejectsInvalidPayloadUnknownFieldsAndTrailingData() throws {
        let invalid = [
            "", "[1,]", "{\"a\":1,}", "{a:1}", "{\"a\" 1}", "[1 2]", "null x", "TRUE", "nul", "--0", "1e", "01",
            "\"\n\"", "\"\\x\"", "\"\\u000g\"", "\"\\u12\"", "\"\\ud800\"", "\"\\udc00\"", "\"\\ud800\\u0041\"",
            "\"unterminated", "\"trailing\\", "\"escaped\\n", "\"escaped\\n\n\"", #"{"a":1 "b":2}"#,
        ]
        for name in ["data", "unknown"] {
            for value in invalid {
                XCTAssertThrowsError(try JSONEnvelope.decode(Data("{\"\(name)\":\(value)}".utf8)), value)
            }
        }
        for text in ["", "[]", "null", "{", "{}x", "{}{}", "{\"data\":0,}", "{\"data\":0 \"x\":1}"] {
            XCTAssertThrowsError(try JSONEnvelope.decode(Data(text.utf8)), text)
        }
        for bytes: [UInt8] in [[0xff], [0xc0, 0x80], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80], [0xc2]] {
            let data = Data(#"{"data":""#.utf8) + Data(bytes) + Data(#""}"#.utf8)
            XCTAssertThrowsError(try JSONEnvelope.decode(data))
        }
    }

    func testSkipEnforcesTheSameDepthAndArrayLimits() throws {
        for depth in [127, 128, 129] {
            let array = String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)
            let object = String(repeating: "{\"x\":", count: depth) + "0" + String(repeating: "}", count: depth)
            for payload in [array, object] {
                for key in ["data", "unknown"] {
                    let data = Data("{\"\(key)\":\(payload)}".utf8)
                    let limit = key == "data" ? 128 : 127
                    if depth <= limit {
                        XCTAssertNoThrow(try JSONEnvelope.decode(data))
                    } else {
                        XCTAssertThrowsError(try JSONEnvelope.decode(data))
                    }
                }
            }
        }
        let elements = String(repeating: "0,", count: 999_999) + "0"
        XCTAssertNoThrow(try JSONEnvelope.decode(Data("{\"data\":[\(elements)]}".utf8)))
        XCTAssertThrowsError(try JSONEnvelope.decode(Data("{\"data\":[\(elements),0]}".utf8)))
    }

    func testSkippedGrammarMatchesMaterializedGrammarUnderByteMutations() throws {
        let original = Data(
            #"{"data":[{"s":"東京\ud83d\ude00\n\t\b\f\r\/\\\"","n":-12.34E-005,"b":false,"a":[null,true]}]}"#.utf8)
        for index in original.indices {
            XCTAssertThrowsError(try JSONEnvelope.decode(original.prefix(index)))
            for byte in [UInt8(0), 34, 44, 58, 92, 125, 255] {
                var mutated = original
                mutated[index] = byte
                let expected = try? JSONReader.decode(mutated)
                let result = try? JSONEnvelope.decode(mutated)
                XCTAssertEqual(result != nil, expected != nil, "index=\(index), byte=\(byte)")
                if let result, case .object(let values) = expected {
                    if let data = result.responseData {
                        XCTAssertEqual(try JSONReader.decode(data), values["data"])
                    } else {
                        XCTAssertNil(values["data"])
                    }
                }
            }
        }
    }
}
