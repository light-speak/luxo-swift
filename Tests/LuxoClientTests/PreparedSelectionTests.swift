import Foundation
import XCTest
@testable import LuxoClient

private func selectionSchema(_ id: Int) -> APISchema {
    APISchema(
        id: 1, fields: ["user": .init(fieldID: 1, typeName: "User")],
        types: ["User": ["id": .init(fieldID: id), "name": .init(fieldID: 2)]])
}

private struct PlannedRequest: GeneratedRequest {
    let apiID = 1
    let selection: String?
    let selectionPlan: PreparedSelection?
    func writeParameters(to encoder: inout Encoder) throws {}
    func toJSONParameters() throws -> [String: LuxoValue] { [:] }
}

final class PreparedSelectionTests: XCTestCase {
    func testBoundAndUnboundPlansPreserveWireAndSchemaIsolation() throws {
        let first = selectionSchema(1)
        let other = selectionSchema(65535)
        for plan in [try PreparedSelection("user{id}", schema: first), try PreparedSelection("user{id}")] {
            for schema in [first, other, first] {
                let request = PlannedRequest(selection: plan.text, selectionPlan: plan)
                let expected = try LuxoBinaryProtocol.encodeRequest(
                    schema: schema, params: ["$select": .string(plan.text)])
                var bytes = try LuxoBinaryProtocol.encodeRequest(schema: schema, request: request)
                XCTAssertEqual(bytes, expected)
                bytes.resetBytes(in: 0..<bytes.count)
                XCTAssertEqual(try LuxoBinaryProtocol.encodeRequest(schema: schema, request: request), expected)
                XCTAssertEqual(
                    try LuxoBinaryProtocol.encodeRequest(
                        schema: schema,
                        request: PlannedRequest(selection: "user{name}", selectionPlan: plan)),
                    try LuxoBinaryProtocol.encodeRequest(schema: schema, params: ["$select": .string("user{name}")]))
            }
        }
    }

    func testInvalidPlansFailExplicitly() throws {
        for text in ["", " \t\r\n", "user{", "id,id"] { XCTAssertThrowsError(try PreparedSelection(text)) }
        XCTAssertThrowsError(try PreparedSelection("missing", schema: selectionSchema(1)))
    }

    func testEmptyManualSelectionsCannotReuseAValidPlan() throws {
        let schema = selectionSchema(1)
        let plan = try PreparedSelection("user{id}", schema: schema)
        for text in ["", " ", "\n", "\t\r\n"] {
            XCTAssertThrowsError(
                try LuxoBinaryProtocol.encodeRequest(
                    schema: schema, request: PlannedRequest(selection: text, selectionPlan: plan)))
            XCTAssertThrowsError(
                try LuxoBinaryProtocol.encodeRequest(
                    schema: schema, params: ["$select": .string(text)]))
        }
    }

    func testPlansAreSafeAcrossConcurrentSchemaValues() throws {
        let schemas = [selectionSchema(1), selectionSchema(3)]
        let plan = try PreparedSelection("user{id}", schema: schemas[0])
        let expected = try schemas.map {
            try LuxoBinaryProtocol.encodeRequest(schema: $0, params: ["$select": .string(plan.text)])
        }
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            do {
                for iteration in 0..<100 {
                    let choice = (index + iteration) % schemas.count
                    let bytes = try LuxoBinaryProtocol.encodeRequest(
                        schema: schemas[choice],
                        request: PlannedRequest(selection: plan.text, selectionPlan: plan))
                    XCTAssertEqual(bytes, expected[choice])
                }
            } catch { XCTFail("\(error)") }
        }
    }
}
