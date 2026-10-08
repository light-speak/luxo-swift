import Foundation
import XCTest
@testable import LuxoCompiler

final class ProjectionInferenceTests: XCTestCase {
    func testAliasesShadowingAndIndependentCalls() throws {
        let ast = root([
            binding("a", call(10)), binding("alias", ref("a")), field(ref("alias"), "id"),
            block([binding("a", call(20)), field(ref("a"), "name")]),
            field(field(ref("a"), "friend"), "name"),
        ])
        let result = try infer(ast)
        XCTAssertEqual(Set(result[10] ?? []), Set([["id"], ["friend", "name"]]))
        XCTAssertEqual(result[20], [["name"]])
    }

    func testEscapesAndUnusedCallsFail() throws {
        for body in [
            [binding("a", call(10)), ["_kind": "return_stmt", "result": ref("a")]],
            [binding("a", call(10)), ["_kind": "erasure_expr", "sub_expr": ref("a")]],
            [binding("a", call(10))],
        ] {
            XCTAssertThrowsError(try infer(root(body)))
        }
    }

    func testComputedPropertyReadsAreIncluded() throws {
        let property: [String: Any] = [
            "_kind": "var_decl",
            "accessors": [
                [
                    "_kind": "accessor_decl",
                    "body": block([field(ref("a"), "name")]),
                ]
            ],
        ]
        let result = try infer(root([binding("a", call(10)), field(ref("a"), "id"), property]))
        XCTAssertEqual(Set(result[10] ?? []), Set([["id"], ["name"]]))
    }

    func testSubscriptionAndListClosure() throws {
        let row = closure(field(ref("row"), "name"))
        let stream: [String: Any] = [
            "_kind": "call_expr", "range": ["start": 10, "end": 11],
            "fn": ["_kind": "declref_expr", "decl": ["decl_usr": "watch"]],
            "args": ["args": [["label": "handler", "expr": row]]],
        ]
        let each: [String: Any] = [
            "_kind": "call_expr",
            "fn": [
                "_kind": "dot_syntax_call_expr",
                "fn": ["_kind": "declref_expr", "decl": ["decl_usr": "s:STsE7forEachyyy7ElementQzKXEKF"]],
                "args": ["args": [["expr": ref("list")]]],
            ],
            "args": ["args": [["expr": row]]],
        ]
        let result = try infer(root([stream, binding("list", call(20)), each]))
        XCTAssertEqual(result[10], [["name"]])
        XCTAssertEqual(result[20], [["name"]])
    }

    private func infer(_ object: [String: Any]) throws -> [Int: [[String]]] {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try ProjectionInference.infer(
            data: data, apis: ["api": .init(), "watch": .init(handler: "handler")],
            fields: [
                "id": .init(name: "id"), "name": .init(name: "name"), "friend": .init(name: "friend", structured: true),
            ])
    }

    private func root(_ nodes: [[String: Any]]) -> [String: Any] {
        ["_kind": "source_file", "items": [["_kind": "func_decl", "body": block(nodes)]]]
    }
    private func block(_ nodes: [[String: Any]]) -> [String: Any] { ["_kind": "brace_stmt", "elements": nodes] }
    private func ref(_ name: String) -> [String: Any] {
        ["_kind": "declref_expr", "decl": ["base_name": name, "decl_usr": ""]]
    }
    private func field(_ base: [String: Any], _ symbol: String) -> [String: Any] {
        ["_kind": "member_ref_expr", "base": base, "decl": ["decl_usr": symbol]]
    }
    private func call(_ offset: Int) -> [String: Any] {
        [
            "_kind": "call_expr", "range": ["start": offset, "end": offset + 1],
            "fn": ["_kind": "declref_expr", "decl": ["decl_usr": "api"]],
        ]
    }
    private func binding(_ name: String, _ value: [String: Any]) -> [String: Any] {
        [
            "_kind": "pattern_binding_decl",
            "pattern_entries": [
                [
                    "pattern": ["_kind": "pattern_named", "name": ["base_name": ["name": name]]],
                    "processed_init": value,
                ]
            ],
        ]
    }
    private func closure(_ value: [String: Any]) -> [String: Any] {
        [
            "_kind": "closure_expr", "params": ["params": [["name": ["base_name": ["name": "row"]]]]],
            "body": block([value]),
        ]
    }
}
