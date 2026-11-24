import Foundation
import XCTest
@testable import LuxoCompiler

final class ProjectionInferenceTests: XCTestCase {
    func testTypedForInUsesTheResolvedSequence() throws {
        let directory = try typedLoopWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cases: [(String, [[String]])] = [
            ("let rows = client.rows(); for row in rows { print(row.id) }", [["id"]]),
            ("let page = client.page(); for row in page.items { print(row.id) }", [["id"]]),
            ("for row in client.page().items { print(row.id) }", [["id"]]),
            ("for parent in client.rows() { for child in parent.children { print(child.id) } }", [["children", "id"]]),
            ("let rows = client.rows(); for row in rows where row.id > 0 { print(row.id) }", [["id"]]),
            ("let rows = client.rows(); print(rows[0].id); for number in 0..<2 { print(number) }", [["id"]]),
        ]
        for (source, expected) in cases {
            let result = try inferTypedLoop(source, in: directory)
            XCTAssertEqual(Array(result.values), [expected], source)
        }
    }

    func testTypedForInRejectsOpaqueSequenceAndElementUses() throws {
        let directory = try typedLoopWorkspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        for source in [
            "let page = client.page(); for row in page.items { print(row.id); opaque(row) }",
            "let rows = client.rows(); print(rows[0].id); for row in opaqueRows(rows) { print(row.id) }",
            "let row = client.row(); print(row.id); for item in row { print(item.id) }",
            "let rows = client.array(); for item in rows { print(item.id) }",
        ] {
            XCTAssertThrowsError(try inferTypedLoop(source, in: directory), source) { error in
                guard case ProjectionInference.Failure.objectEscapes = error else {
                    return XCTFail("Expected an escaping model, got \(error)")
                }
            }
        }
    }

    func testForInRejectsMalformedResolvedIterators() throws {
        func iterator(_ arguments: [[String: Any]]?) -> [String: Any] {
            var method: [String: Any] = [
                "_kind": "dot_syntax_call_expr",
                "fn": [
                    "_kind": "declref_expr", "decl": ["decl_usr": "s:Slss16IndexingIteratorVyxG0B0RtzrlE04makeB0ACyF"],
                ],
            ]
            if let arguments { method["args"] = ["args": arguments] }
            return ["_kind": "call_expr", "fn": method]
        }
        let initializers: [[String: Any]?] = [
            nil, ["_kind": "integer_literal_expr"], iterator(nil), iterator([]),
            iterator([[:], [:]]), iterator([[:]]),
        ]
        for initializer in initializers {
            let entry = initializer.map { ["processed_init": $0] } ?? [:]
            let loop: [String: Any] = [
                "_kind": "for_each_stmt", "iterator_var": ["pattern_entries": [entry]],
            ]
            XCTAssertThrowsError(try infer(root([loop]))) { error in
                XCTAssertEqual(error as? ProjectionInference.Failure, .invalidAST)
            }
        }
        for entries in [[], [[:], [:]]] as [[[String: Any]]] {
            let loop: [String: Any] = ["_kind": "for_each_stmt", "iterator_var": ["pattern_entries": entries]]
            XCTAssertThrowsError(try infer(root([loop]))) { error in
                XCTAssertEqual(error as? ProjectionInference.Failure, .invalidAST)
            }
        }
        XCTAssertThrowsError(try infer(root([["_kind": "for_each_stmt"]]))) { error in
            XCTAssertEqual(error as? ProjectionInference.Failure, .invalidAST)
        }
        var unknown: [String: Any] = ref("rows")
        for _ in 0..<16 { unknown = ["_kind": "unknown_expr", "sub_expr": unknown] }
        unknown["type"] = "$sSay9LoopProbe3RowVGD"
        for initializer in [iterator([["expr": unknown]]), ["_kind": "call_expr", "fn": unknown]] {
            let loop: [String: Any] = [
                "_kind": "for_each_stmt", "iterator_var": ["pattern_entries": [["processed_init": initializer]]],
            ]
            XCTAssertThrowsError(try infer(root([binding("rows", call(10)), field(ref("rows"), "id"), loop]))) {
                error in
                XCTAssertEqual(error as? ProjectionInference.Failure, .objectEscapes(10, "declref_expr"))
            }
        }
        let unrelated: [String: Any] = [
            "_kind": "call_expr",
            "fn": [
                "_kind": "dot_syntax_call_expr",
                "fn": ["_kind": "declref_expr", "decl": ["decl_usr": "other.makeIterator"]],
                "args": ["args": [["expr": ref("numbers")]]],
            ],
        ]
        let loop: [String: Any] = [
            "_kind": "for_each_stmt", "iterator_var": ["pattern_entries": [["processed_init": unrelated]]],
            "pattern": ["_kind": "pattern_named", "name": ["base_name": ["name": "number"]]],
        ]
        let result = try infer(root([binding("rows", call(10)), field(ref("rows"), "id"), loop]))
        XCTAssertEqual(result[10], [["id"]])
    }

    func testPageMetadataDoesNotEnterTheModelSelection() throws {
        let ast = root([
            binding("page", call(10)), field(ref("page"), "total"), field(ref("page"), "page"),
            field(ref("page"), "pageSize"), binding("rows", field(ref("page"), "items")),
            field(ref("rows"), "id"),
        ])
        let data = try JSONSerialization.data(withJSONObject: ast)
        let result = try ProjectionInference.infer(
            data: data, apis: ["api": .init()], fields: ["id": .init(name: "id")],
            transparent: ["items"], metadata: ["total", "page", "pageSize"])
        XCTAssertEqual(result[10], [["id"]])
    }

    func testMetadataSymbolsDoNotAdmitBusinessMembersOrAnEmptySelection() throws {
        for body in [
            [binding("page", call(10)), field(ref("page"), "business.total"), field(ref("page"), "id")],
            [binding("page", call(10)), field(ref("page"), "total")],
            [
                binding("page", call(10)), field(ref("page"), "total"), binding("other", call(20)),
                field(ref("other"), "id"),
            ],
        ] {
            let data = try JSONSerialization.data(withJSONObject: root(body))
            XCTAssertThrowsError(
                try ProjectionInference.infer(
                    data: data, apis: ["api": .init()], fields: ["id": .init(name: "id")], metadata: ["total"]))
        }
    }

    func testAggregateChildrenCannotHideAnEscapingModel() throws {
        for kind in ["array_expr", "dictionary_expr", "tuple_expr"] {
            let aggregate: [String: Any] = ["_kind": kind, "elements": [ref("a")]]
            let ast = root([binding("a", call(10)), field(ref("a"), "id"), binding("box", aggregate)])
            XCTAssertThrowsError(try infer(ast)) { error in
                guard case ProjectionInference.Failure.objectEscapes(let offset, _) = error else {
                    return XCTFail("Expected model escape for \(kind), got \(error)")
                }
                XCTAssertEqual(offset, 10)
            }
        }
    }

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

    private func typedLoopWorkspace() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/selection-loop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func inferTypedLoop(_ body: String, in directory: URL) throws -> [Int: [[String]]] {
        let root = directory.deletingLastPathComponent().deletingLastPathComponent()
        let file = directory.appendingPathComponent("Loops.swift")
        let source = """
            public struct Row { public let id: Int; public let children: [Row] }
            public struct PageBox { public let items: [Row] }
            public struct Client {
                public func row(select: String? = nil) -> Row { fatalError() }
                public func rows(select: String? = nil) -> [Row] { [] }
                public func page(select: String? = nil) -> PageBox { fatalError() }
                public func array(select: String? = nil) -> Array { fatalError() }
            }
            func opaque(_ row: Row) {}
            func opaqueRows(_ rows: [Row]) -> [Row] { rows }
            extension Row: Collection {
                public var startIndex: Int { 0 }
                public var endIndex: Int { 1 }
                public func index(after value: Int) -> Int { value + 1 }
                public subscript(position: Int) -> Row { opaque(self); return self }
                public func makeIterator() -> IndexingIterator<[Row]> { opaque(self); return [self].makeIterator() }
            }
            public struct Array: Collection {
                public let storage: [Row]
                public var startIndex: Int { 0 }
                public var endIndex: Int { storage.count }
                public func index(after value: Int) -> Int { value + 1 }
                public subscript(position: Int) -> Row { opaque(storage[position]); return storage[position] }
            }
            func inspect(_ client: Client) { \(body) }
            """
        try source.write(to: file, atomically: true, encoding: .utf8)
        let process = SelectionCompilerProcess(workspace: root, scratch: directory)
        let sdk = String(decoding: try process.run("/usr/bin/xcrun", ["--show-sdk-path"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try process.run(
            "swiftc",
            [
                "-frontend", "-dump-ast", "-dump-ast-format", "json", "-dump-usr", "-sdk", sdk,
                "-module-name", "LoopProbe", "-module-cache-path", directory.appendingPathComponent("cache").path,
                "-parse-as-library", file.path,
            ])
        let ast = try JSONDecoder().decode(CompilerASTValue.self, from: data)
        return try inferResolvedLoop(data: data, root: ast)
    }

    private func inferResolvedLoop(data: Data, root: CompilerASTValue) throws -> [Int: [[String]]] {
        var apis: [String: ProjectionInference.API] = [:]
        var fields: [String: ProjectionInference.Field] = [:]
        var transparent: Set<String> = []
        func symbols(_ node: CompilerASTValue) {
            if let symbol = node["decl"]?["decl_usr"]?.text, !symbol.isEmpty,
                let name = node["decl"]?["base_name"]?.text
            {
                if ["row", "rows", "page", "array"].contains(name) { apis[symbol] = .init() }
                if name == "items" { transparent.insert(symbol) }
                if ["id", "children"].contains(name) {
                    fields[symbol] = .init(name: name, structured: name == "children")
                }
            }
            for child in node.children { symbols(child) }
        }
        symbols(root)
        return try ProjectionInference.infer(data: data, apis: apis, fields: fields, transparent: transparent)
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
