import XCTest
@testable import LuxoClient

final class ErrorTests: XCTestCase {
    func testConstructorFields() {
        let err = LuxoError(code: 404, message: "Not found")
        XCTAssertEqual(err.code, 404)
        XCTAssertEqual(err.message, "Not found")
        XCTAssertEqual(err.name, "Error")
        XCTAssertNil(err.traceId)
        XCTAssertNil(err.data)
    }

    func testConstructorWithAllFields() {
        let data: [String: Any] = ["field": "email"]
        let err = LuxoError(
            code: 422,
            message: "Validation failed",
            name: "ValidationError",
            traceId: "abc-123",
            data: data,
            cause: "database constraint"
        )
        XCTAssertEqual(err.code, 422)
        XCTAssertEqual(err.message, "Validation failed")
        XCTAssertEqual(err.name, "ValidationError")
        XCTAssertEqual(err.traceId, "abc-123")
        XCTAssertEqual((err.data as? [String: Any])?["field"] as? String, "email")
        XCTAssertEqual(err.cause, "database constraint")
    }

    func testLocalizedDescription() {
        let err = LuxoError(code: 500, message: "Internal server error")
        XCTAssertEqual(err.errorDescription, "[Error] Internal server error")
    }

    func testLocalizedDescriptionWithTraceId() {
        let err = LuxoError(code: 500, message: "Internal server error", name: "ServerError", traceId: "trace-xyz")
        XCTAssertEqual(err.errorDescription, "[ServerError] Internal server error (trace: trace-xyz)")
    }

    func testErrorProtocolConformance() {
        let err: Error = LuxoError(code: 401, message: "Unauthorized", name: "Unauthorized")
        XCTAssertEqual(err.localizedDescription, "[Unauthorized] Unauthorized")
    }

    func testFromJSON() {
        let json: [String: Any] = [
            "code": 403,
            "message": "Forbidden",
            "name": "Forbidden",
            "traceId": "req-456",
            "data": ["reason": "insufficient_permissions"],
        ]
        let err = LuxoError.from(json: json)
        XCTAssertEqual(err.code, 403)
        XCTAssertEqual(err.message, "Forbidden")
        XCTAssertEqual(err.name, "Forbidden")
        XCTAssertEqual(err.traceId, "req-456")
        XCTAssertEqual((err.data as? [String: Any])?["reason"] as? String, "insufficient_permissions")
    }

    func testFromJSONWithErrorField() {
        let json: [String: Any] = [
            "code": 401,
            "message": "Token expired",
            "error": "Unauthorized",
        ]
        let err = LuxoError.from(json: json)
        XCTAssertEqual(err.name, "Unauthorized")
    }

    func testFromJSONMissingFields() {
        let json: [String: Any] = [:]
        let err = LuxoError.from(json: json)
        XCTAssertEqual(err.code, 0)
        XCTAssertEqual(err.message, "Unknown error")
        XCTAssertEqual(err.name, "Error")
        XCTAssertNil(err.traceId)
        XCTAssertNil(err.data)
    }

    func testFromJSONPartialFields() {
        let json: [String: Any] = ["code": 500]
        let err = LuxoError.from(json: json)
        XCTAssertEqual(err.code, 500)
        XCTAssertEqual(err.message, "Unknown error")
    }

    func testFromJSONRejectsInexactErrorCodes() throws {
        let tokens = [
            "true", "false", "null", "\"400\"", "[]", "{}", "400.5", "400.0", "4e2",
            "9223372036854775808", "18446744073709551615", "-9223372036854775809",
        ]
        for token in tokens {
            let json = try errorJSON(#""code":\#(token),"error":"RemoteError","message":"failed""#)
            let error = LuxoError.from(json: json)
            XCTAssertEqual(error.name, "ParseError", token)
            XCTAssertEqual(error.code, 0, token)
        }
    }

    func testFromJSONPreservesIntegerStorageWithoutNarrowing() throws {
        for code in [Int.min, -1, 0, 1, 400, 9_007_199_254_740_993, Int.max] {
            let json = try errorJSON(#""code":\#(code),"error":"RemoteError","message":"failed""#)
            XCTAssertEqual(LuxoError.from(json: json).code, code)
        }
    }

    func testFromJSONRejectsMalformedProvidedFields() throws {
        for fields in [
            #""error":null"#, #""error":false"#, #""name":42"#, #""message":null"#,
            #""message":{}"#, #""traceId":42"#, #""cause":[]"#,
        ] {
            XCTAssertEqual(LuxoError.from(json: try errorJSON(fields)).name, "ParseError", fields)
        }
        let json = try errorJSON(#""code":400,"traceId":null,"cause":null,"data":{"id":9223372036854775807}"#)
        let error = LuxoError.from(json: json)
        XCTAssertEqual(error.code, 400)
        XCTAssertNil(error.traceId)
        XCTAssertNil(error.cause)
        XCTAssertEqual((error.data as? [String: Any])?["id"] as? Int64, Int64.max)
    }

    func testResponsePreservesExactCodesAndOptionalFieldsInBothEncodings() throws {
        for code in [Int.min, -1, 0, 400, 9_007_199_254_740_993, Int.max] {
            let json = try errorJSON(
                #""code":\#(code),"error":"RemoteError","message":"failed","traceId":"trace","cause":"cause","data":{"id":9223372036854775807}"#
            )
            var binary = Encoder()
            binary.writeVarint(1)
            binary.writeSvarint(Int64(code))
            for (field, value) in [(2, "RemoteError"), (3, "failed"), (4, "trace"), (6, "cause")] {
                binary.writeVarint(UInt64(field))
                binary.writeString(value)
            }
            binary.writeVarint(5)
            binary.writeBytes(Data(#"{"id":9223372036854775807}"#.utf8))
            binary.writeEnd()
            for error in [
                LuxoError.fromResponse(json: json, statusCode: 502),
                LuxoBinaryProtocol.decodeError(binary.data, statusCode: 502),
            ] {
                XCTAssertEqual(error.code, code)
                XCTAssertEqual(error.name, "RemoteError")
                XCTAssertEqual(error.message, "failed")
                XCTAssertEqual(error.traceId, "trace")
                XCTAssertEqual(error.cause, "cause")
                XCTAssertEqual((error.data as? [String: Any])?["id"] as? Int64, Int64.max)
            }
        }
    }

    func testBinaryErrorRejectsInvalidUTF8InEveryTextField() {
        let required = Data([1, 0xa0, 6, 2, 1, 69, 3, 1, 109])
        for field in 2...6 {
            // Put malformed bytes first so duplicate validation cannot hide an invalid string.
            let data = Data([UInt8(field), 1, 0xff]) + required + Data([0])
            XCTAssertEqual(LuxoBinaryProtocol.decodeError(data, statusCode: 502).name, "ParseError")
        }
    }

    func testBinaryErrorOwnsHeapBackedFieldsAfterDecoderFinishes() {
        let text = String(repeating: "error-details-", count: 32)
        let error: LuxoError = {
            var encoder = Encoder()
            encoder.writeVarint(1)
            encoder.writeSvarint(500)
            for field in [2, 3, 4, 6] {
                encoder.writeVarint(UInt64(field))
                encoder.writeString(text)
            }
            encoder.writeVarint(5)
            encoder.writeBytes(Data("{\"detail\":\"\(text)\"}".utf8))
            encoder.writeEnd()
            return LuxoBinaryProtocol.decodeError(encoder.data, statusCode: 502)
        }()
        XCTAssertEqual(error.code, 500)
        XCTAssertEqual(error.name, text)
        XCTAssertEqual(error.message, text)
        XCTAssertEqual(error.traceId, text)
        XCTAssertEqual(error.cause, text)
        XCTAssertEqual((error.data as? [String: String])?["detail"], text)
    }

    func testBinaryErrorValidatesFieldIDsBeforeBuildingSeenMask() {
        for id in [7, 63, 64, 65, Int.max] {
            var encoder = Encoder()
            encoder.writeVarint(UInt64(id))
            encoder.writeEnd()
            let error = LuxoBinaryProtocol.decodeError(encoder.data, statusCode: 502)
            XCTAssertEqual(error.name, "ParseError")
            XCTAssertTrue(error.message.contains("unknown binary error field"))
        }
    }

    private func errorJSON(_ fields: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data("{\(fields)}".utf8)) as? [String: Any])
    }
}
