import Foundation
import XCTest
@testable import LuxoClient

final class JSONParameterTests: XCTestCase {
    func testOnlyIntegerAndStructuredParametersNeedPlans() {
        XCTAssertNil(APISchema(id: 1).jsonParameters)
        XCTAssertNil(APISchema(id: 1, params: [.init(fieldID: 1, name: "value", type: "Float")]).jsonParameters)
        XCTAssertNil(APISchema(id: 1, params: [], types: ["Unused": [:]]).jsonParameters)
    }

    func testSignedBoundariesAreExactWithoutChangingOpaqueValues() throws {
        let schema = APISchema(id: 1, params: [.init(fieldID: 1, name: "value", type: "Int")])
        for value in [Int64.min, -1, 0, 1, 9_007_199_254_740_993, Int64.max] {
            let encoded = try LuxoJSONRequest.encode(
                api: "echo", params: ["value": .int(value)], plan: schema.jsonParameters)
            XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "{\"$api\":\"echo\",\"value\":\(value)}")
        }
        let params: [String: LuxoValue] = ["opaque": ["value": .float(1.5)], "value": .int(Int64.max)]
        let object = try object(params, schema: schema)
        XCTAssertEqual((object["opaque"] as? [String: Double])?["value"], 1.5)
        XCTAssertEqual(object["value"] as? Int64, Int64.max)
        XCTAssertNil(try self.object([:], schema: schema)["value"])
    }

    func testNullableIntegerListsDoNotMakeElementsNullable() throws {
        let schema = APISchema(
            id: 1,
            params: [
                .init(fieldID: 1, name: "value", type: "Duration", isList: true, nullable: true)
            ])
        XCTAssertTrue(try object(["value": .null], schema: schema)["value"] is NSNull)
        XCTAssertEqual(try object(["value": .array([])], schema: schema)["value"] as? [Int64], [])
        let values: [LuxoValue] = [.int(Int64.min), .int(Int64.max)]
        XCTAssertEqual(
            try object(["value": .array(values)], schema: schema)["value"] as? [Int64], [Int64.min, Int64.max])
        assertInvalid(["value": .int(1)], schema: schema, path: "value")
        for bad: LuxoValue in [.null, .float(1), .bool(false), .string("1"), .array([]), .object([:])] {
            assertInvalid(["value": .array([.int(1), bad])], schema: schema, path: "value[1]")
        }
    }

    func testRecursiveObjectsValidateOnlyPresentTypedFields() throws {
        let schema = recursiveSchema()
        let valid: LuxoValue = [
            "id": .int(Int64.max), "next": ["id": .int(Int64.min), "next": .null],
            "children": .array([]), "metadata": ["id": .float(1.5)], "ratio": .float(1.5),
        ]
        let result = try object(["value": valid], schema: schema)["value"] as? [String: Any]
        XCTAssertEqual(result?["id"] as? Int64, Int64.max)
        XCTAssertEqual((result?["next"] as? [String: Any])?["id"] as? Int64, Int64.min)
        XCTAssertEqual((result?["metadata"] as? [String: Double])?["id"], 1.5)
        let bad: LuxoValue = ["children": .array([.object([:]), .object(["next": ["id": .bool(true)]])])]
        assertInvalid(["value": bad], schema: schema, path: "value.children[1].next.id")
        assertInvalid(["value": .null], schema: schema, path: "value")
        assertInvalid(["value": .array([])], schema: schema, path: "value")
        assertInvalid(["value": ["children": .array([.null])]], schema: schema, path: "value.children[0]")
    }

    func testMissingModelAndFieldMetadataFailsExplicitly() throws {
        for name in [nil, "Missing"] {
            let schema = APISchema(
                id: 1,
                params: [
                    .init(fieldID: 1, name: "value", type: "Model", typeName: name, nullable: true)
                ])
            XCTAssertTrue(try object(["value": .null], schema: schema)["value"] is NSNull)
            assertInvalid(["value": .object([:])], schema: schema, path: "value")
        }
        let partial = APISchema(
            id: 1, params: [.init(fieldID: 1, name: "value", type: "Model", typeName: "Partial")],
            types: [
                "Partial": ["unknown": .init(fieldID: 1), "child": .init(fieldID: 2, typeName: "Missing")]
            ])
        assertInvalid(["value": ["unknown": .int(1)]], schema: partial, path: "value.unknown")
        assertInvalid(["value": ["child": .object([:])]], schema: partial, path: "value.child")
        XCTAssertNotNil(try object(["value": .object([:])], schema: partial)["value"])
    }

    func testNamedAndEmptyModelsUseTheSameCompiledMetadata() throws {
        let schema = APISchema(id: 1, params: [.init(fieldID: 1, name: "value", type: "Input")], types: ["Input": [:]])
        XCTAssertEqual((try object(["value": .object([:])], schema: schema)["value"] as? [String: Int])?.count, 0)
        assertInvalid(["value": .bool(true)], schema: schema, path: "value")
    }

    func testStructuredInputsAreProjectedExactlyOnce() throws {
        let counter = Counter()
        let value = ProjectedInput(counter: counter, id: .int(Int64.max))
        let object = try object(["value": .structured(value)], schema: recursiveSchema())
        XCTAssertEqual((object["value"] as? [String: Any])?["id"] as? Int64, Int64.max)
        XCTAssertEqual(counter.count, 1)
        assertInvalid(
            ["value": .structured(ProjectedInput(counter: counter, id: .float(1)))],
            schema: recursiveSchema(), path: "value.id")
        XCTAssertEqual(counter.count, 2)
    }

    func testRecursiveInputDepthIsBounded() {
        var value: LuxoValue = ["id": .int(1)]
        for _ in 0..<140 { value = ["next": value] }
        assertInvalid(["value": value], schema: recursiveSchema(), path: "value.next")
        assertInvalid(["value": .structured(RecursiveProjection())], schema: recursiveSchema(), path: "value")
    }

    func testRequestMetadataCannotBeOverriddenInEitherJSONEnvelope() throws {
        let params: [String: LuxoValue] = [
            "$api": .float(.nan), "$id": .float(.infinity), "$sub": .float(-.infinity), "$select": "id",
        ]
        for subscription in [false, true] {
            let data = try LuxoJSONRequest.encode(api: "echo", params: params, plan: nil, subscription: subscription)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
            XCTAssertEqual(object, [subscription ? "$sub" : "$api": "echo", "$select": "id"])
        }
        let frame = try LuxoJSONRequest.encode(api: "echo", params: params, plan: nil, sequence: UInt64.max)
        XCTAssertTrue(String(decoding: frame, as: UTF8.self).contains("18446744073709551615"))
        XCTAssertEqual(try LuxoJSONRequest.encode(api: "echo", params: nil, plan: nil), Data(#"{"$api":"echo"}"#.utf8))
    }

    func testNonFiniteOpaqueFieldsStillReportEncodingError() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try object(["value": ["ratio": .float(value)]], schema: recursiveSchema())) { error in
                XCTAssertEqual((error as? LuxoError)?.name, "EncodingError")
            }
        }
    }

    private func recursiveSchema() -> APISchema {
        APISchema(
            id: 1, params: [.init(fieldID: 1, name: "value", type: "Model", typeName: "Input")],
            types: [
                "Input": [
                    "id": .init(fieldID: 1, type: "Int"),
                    "next": .init(fieldID: 2, typeName: "Input", type: "Model", nullable: true),
                    "children": .init(fieldID: 3, typeName: "Input", type: "Model", isList: true),
                    "metadata": .init(fieldID: 4, type: "JSON"), "ratio": .init(fieldID: 5, type: "Float"),
                ]
            ])
    }

    private func object(_ params: [String: LuxoValue], schema: APISchema) throws -> [String: Any] {
        let data = try LuxoJSONRequest.encode(api: "echo", params: params, plan: schema.jsonParameters)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertInvalid(
        _ params: [String: LuxoValue], schema: APISchema, path: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try object(params, schema: schema), file: file, line: line) { error in
            XCTAssertEqual((error as? LuxoError)?.name, "ConfigError", file: file, line: line)
            XCTAssertTrue((error as? LuxoError)?.message.contains(path) ?? false, "\(error)", file: file, line: line)
        }
    }

    private final class Counter: @unchecked Sendable {
        var count = 0
    }

    private struct ProjectedInput: Encodable, LuxoBinaryEncodable {
        let counter: Counter
        let id: LuxoValue

        func encode(to encoder: any Swift.Encoder) throws {
            XCTFail("must not perform an intermediate JSON round trip")
        }
        func writeLuxo(to encoder: inout LuxoClient.Encoder) throws { XCTFail("JSON must not run the binary writer") }
        func luxoJSONValue() throws -> LuxoValue {
            counter.count += 1
            return ["id": id]
        }
    }

    private struct RecursiveProjection: Encodable, LuxoBinaryEncodable {
        func writeLuxo(to encoder: inout LuxoClient.Encoder) throws { XCTFail("not a binary fixture") }
        func luxoJSONValue() throws -> LuxoValue { .structured(self) }
    }
}
